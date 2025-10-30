import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'screens/channel_management_screen.dart';
import 'screens/download_manager_screen.dart';
import 'screens/audio_player_screen.dart';
import 'services/database_service.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'services/youtube_service.dart';
import 'services/download_service.dart';
import 'package:workmanager/workmanager.dart';
import 'dart:io';
import 'services/notification_service.dart';
import 'core/snackbar_bus.dart';
import 'models/video.dart';
import 'models/channel.dart';
import 'dart:async';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'theme/app_theme.dart';
import 'theme/theme_notifier.dart';

const fetchTask = 'fetchNewVideosTask';

final RouteObserver<PageRoute> routeObserver = RouteObserver<PageRoute>();

Future<void> _requestNotificationPermission() async {
  try {
    if (Platform.isAndroid) {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      print('Android SDK version: ${androidInfo.version.sdkInt}');

      if (androidInfo.version.sdkInt >= 33) {
        print('Android 13+ detected, requesting notification permission...');
        final status = await Permission.notification.status;
        print('Current notification permission status: $status');

        if (await Permission.notification.isDenied) {
          print('Notification permission denied, requesting...');
          final result = await Permission.notification.request();
          print('Notification permission request result: $result');
        } else {
          print(
            'Notification permission already granted or permanently denied',
          );
        }
      } else {
        print('Android version < 13, notification permission not required');
      }
    }
  } catch (e) {
    print('Error requesting notification permission: $e');
  }
}

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task == fetchTask) {
      await NotificationService.init();
      await backgroundTask();
    }
    return Future.value(true);
  });
}

@pragma('vm:entry-point')
Future<void> backgroundTask() async {
  final prefs = await SharedPreferences.getInstance();
  // Check if we should skip the first background run (e.g., after manual download or first install)
  final skipFirstBackgroundRun =
      prefs.getBool('skip_first_background_run') ?? false;
  if (skipFirstBackgroundRun) {
    print(
      'Background task: Skipping first run after manual download or install.',
    );
    await prefs.setBool(
      'skip_first_background_run',
      false,
    ); // Reset for next run
    return;
  }
  final channels = await DatabaseService.instance.getChannels();
  for (final channel in channels) {
    try {
      final videos = await YouTubeService.fetchChannelVideos(channel.id);
      if (videos.isEmpty) continue;

      // Sort videos by published date (newest first)
      videos.sort((a, b) => b.published.compareTo(a.published));

      // Find the index of the last processed video
      int lastIndex = videos.indexWhere((v) => v.id == channel.lastVideoId);
      List<Video> newVideos;

      if (lastIndex == -1) {
        // lastVideoId not found (first run or channel changed), but if lastVideoId is set, skip background download
        if (channel.lastVideoId.isNotEmpty) {
          print(
            'Background task: ${channel.name} - lastVideoId set but not found, skipping background download.',
          );
          continue;
        }
        // If lastVideoId is empty, process the single latest video (first install, legacy case)
        newVideos = videos.take(1).toList();
      } else if (lastIndex == 0) {
        // lastVideoId is already the newest video - no new videos to download
        print(
          'Background task: ${channel.name} - No new videos (latest already downloaded)',
        );
        continue;
      } else if (lastIndex > 0) {
        // There are newer videos than the lastVideoId
        newVideos = videos.sublist(0, lastIndex);
      } else {
        // No new videos
        newVideos = [];
      }

      if (newVideos.isEmpty) {
        print('Background task: ${channel.name} - No new videos to download');
        continue;
      }

      print(
        'Background task: ${channel.name} - Found ${newVideos.length} new videos to download',
      );

      // Process new videos (limit to first 5 to avoid overwhelming the system)
      // Download in chronological order (oldest first)
      newVideos = newVideos.reversed.toList();
      int processedCount = 0;
      String? lastDownloadedId;

      for (final video in newVideos.take(1)) {
        final isDownloaded = await DownloadService.isVideoDownloaded(video.id);
        if (!isDownloaded) {
          print('Background task: Downloading ${video.title}');
          final downloaded = await DownloadService.downloadAudio(
            videoId: video.id,
            videoUrl: 'https://www.youtube.com/watch?v=${video.id}',
            title: video.title,
            channelName: video.channelName,
            thumbnailUrl: video.thumbnailUrl,
          );
          if (downloaded != null) {
            processedCount++;
            lastDownloadedId = video.id;
            await NotificationService.showNotification(
              title: 'New Audio Downloaded',
              body: 'Downloaded audio for ${video.title}',
            );
          } else {
            // Stop processing further videos if a download fails
            print(
              'Background task: Download failed for ${video.title}, stopping',
            );
            break;
          }
        } else {
          // Already downloaded, but still update lastDownloadedId
          print('Background task: ${video.title} already downloaded, skipping');
          lastDownloadedId = video.id;
        }
      }

      // Update the last processed video ID to the last successfully downloaded (or already downloaded) video
      if (lastDownloadedId != null) {
        final updatedChannel = Channel(
          id: channel.id,
          name: channel.name,
          description: channel.description,
          thumbnailUrl: channel.thumbnailUrl,
          lastVideoId: lastDownloadedId,
        );
        await DatabaseService.instance.updateChannel(updatedChannel);
        print(
          'Background task: Updated lastVideoId to $lastDownloadedId for ${channel.name}',
        );
      }

      // Show summary notification if any videos were downloaded
      if (processedCount > 0) {
        await NotificationService.showNotification(
          title: 'Background Download Complete',
          body:
              'Downloaded $processedCount new audio files from ${channel.name}',
        );
        print(
          'Background task: Completed downloading $processedCount videos from ${channel.name}',
        );
      } else {
        print('Background task: No new videos downloaded from ${channel.name}');
      }
    } catch (e) {
      print('Error processing channel ${channel.name}: $e');
      // Continue with other channels even if one fails
    }
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _requestNotificationPermission();
  print('Notification permission requested');

  print('Initializing JustAudioBackground...');
  await JustAudioBackground.init(
    androidNotificationChannelId:
        'com.example.youtube_audio_downloader.channel.audio',
    androidNotificationChannelName: 'Audio playback',
    androidNotificationOngoing: true,
    fastForwardInterval: Duration(seconds: 10),
    rewindInterval: Duration(seconds: 10),
  );
  print('JustAudioBackground initialized successfully');

  // Test notification permission
  if (Platform.isAndroid) {
    final androidInfo = await DeviceInfoPlugin().androidInfo;
    if (androidInfo.version.sdkInt >= 33) {
      final status = await Permission.notification.status;
      print('Final notification permission status: $status');
      if (status.isDenied) {
        print('WARNING: Notification permission is still denied!');
      }
    }
  }

  await DownloadService.init();
  await DownloadService.resumeIncompleteDownloads();
  await DatabaseService.instance.db;
  await NotificationService.init();
  if (Platform.isAndroid) {
    await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);
    await Workmanager().registerPeriodicTask(
      'fetch_new_videos_task',
      fetchTask,
      frequency: const Duration(hours: 15),
      initialDelay: const Duration(minutes: 1),
      constraints: Constraints(networkType: NetworkType.connected),
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(minutes: 10),
    );
  }
  await DownloadService.restoreGlobalPlayerState();
  final themeNotifier = ThemeNotifier();
  await themeNotifier.loadTheme();
  runApp(
    ChangeNotifierProvider.value(value: themeNotifier, child: const MyApp()),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeNotifier>(
      builder: (context, notifier, _) {
        return MaterialApp(
          title: 'YT AudioBox',
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: notifier.themeMode,
          scaffoldMessengerKey: scaffoldMessengerKey,
          home: const ChannelManagementScreen(),
          routes: {
            '/home': (_) => const ChannelManagementScreen(),
            '/downloads': (_) => const DownloadManagerScreen(),
            '/player': (_) => const AudioPlayerScreen(),
          },
          debugShowCheckedModeBanner: false,
          navigatorObservers: [routeObserver],
        );
      },
    );
  }
}
