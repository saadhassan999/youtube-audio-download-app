import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import '../models/downloaded_video.dart';
import 'database_service.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:just_audio/just_audio.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Helper class to hold playing state
class PlayingAudio {
  final String videoId;
  final bool isPlaying;
  PlayingAudio(this.videoId, this.isPlaying);
}

class DownloadService {
  // Global audio player singleton, initialized after JustAudioBackground.init
  static late final AudioPlayer globalAudioPlayer;
  static bool _audioPlayerInitialized = false;
  // Global notifier for currently playing videoId and playing state
  static final ValueNotifier<PlayingAudio?> globalPlayingNotifier = ValueNotifier<PlayingAudio?>(null);
  static final ValueNotifier<int> downloadedVideosChanged = ValueNotifier<int>(0);
  static final ValueNotifier<Map<String, double>> downloadProgressNotifier = ValueNotifier({});
  static final ValueNotifier<bool> isAnyDownloadInProgress = ValueNotifier<bool>(false);
  static final Map<String, bool> _downloadCancelFlags = {};
  static final Set<String> _activeDownloads = {};

  static Future<void> init() async {
    if (!_audioPlayerInitialized) {
      globalAudioPlayer = AudioPlayer();
      _audioPlayerInitialized = true;
      ensureInitialized();
    }
  }

  // Static initializer to sync notifier with player state
  static bool _initialized = false;
  // Keys for saving state
  static const String _lastVideoIdKey = 'global_last_video_id';
  static const String _lastVideoPositionKey = 'global_last_video_position';
  static const String _lastVideoStateKey = 'global_last_video_state';

  static void ensureInitialized() {
    if (_initialized) return;
    _initialized = true;
    globalAudioPlayer.playerStateStream.listen((state) {
      final current = globalPlayingNotifier.value;
      if (state.processingState == ProcessingState.completed || state.processingState == ProcessingState.idle) {
        globalPlayingNotifier.value = null;
      } else if (state.playing) {
        if (current != null) {
          globalPlayingNotifier.value = PlayingAudio(current.videoId, true);
        }
      } else {
        if (current != null) {
          globalPlayingNotifier.value = PlayingAudio(current.videoId, false);
        }
      }
      // Save state on any player state change
      saveGlobalPlayerState();
    });
    // Save position periodically
    globalAudioPlayer.positionStream.listen((pos) {
      saveGlobalPlayerState();
    });
  }

  static Future<void> stopGlobalAudio() async {
    if (globalAudioPlayer.playing) {
      await globalAudioPlayer.stop();
      globalPlayingNotifier.value = null;
    }
  }

  @pragma('vm:entry-point')
  static Future<bool> isVideoDownloaded(String videoId) async {
    final video = await DatabaseService.instance.getDownloadedVideo(videoId);
    if (video == null) return false;
    return File(video.filePath).existsSync();
  }

  @pragma('vm:entry-point')
  static Future<String?> getDownloadedFilePath(String videoId) async {
    final video = await DatabaseService.instance.getDownloadedVideo(videoId);
    if (video == null) return null;
    return File(video.filePath).existsSync() ? video.filePath : null;
  }

  @pragma('vm:entry-point')
  static Future<DownloadedVideo?> downloadAudio({
    required String videoId,
    required String videoUrl,
    required String title,
    required String channelName,
    required String thumbnailUrl,
    void Function(int received, int total)? onProgress,
    bool resume = false,
  }) async {
    if (_activeDownloads.contains(videoId)) {
      // Already running
      return null;
    }
    _activeDownloads.add(videoId);
    final dir = await getApplicationDocumentsDirectory();
    final filePath = '${dir.path}/$videoId.mp3';
    final file = File(filePath);
    // Delete any old .m4a file for this videoId
    final oldM4a = File('${dir.path}/$videoId.m4a');
    if (await oldM4a.exists()) {
      await oldM4a.delete();
    }
    _downloadCancelFlags[videoId] = false;
    // Only insert a 'downloading' record if not resuming
    if (!resume) {
      final downloadingVideo = DownloadedVideo(
        videoId: videoId,
        title: title,
        filePath: filePath,
        size: 0,
        duration: null,
        channelName: channelName,
        thumbnailUrl: thumbnailUrl,
        downloadedAt: DateTime.now(),
        status: 'downloading',
      );
      await DatabaseService.instance.addDownloadedVideo(downloadingVideo);
      downloadedVideosChanged.value++;
      isAnyDownloadInProgress.value = true;
    }
    final yt = YoutubeExplode();
    try {
      // Get video manifest (API updated for v2.x)
      final manifest = await yt.videos.streams.getManifest(videoId);
      final audioStreamInfo = manifest.audioOnly.withHighestBitrate();
      if (audioStreamInfo == null) {
        print('No audio stream found for video: $videoId');
        // Mark as failed instead of deleting
        final failedVideo = DownloadedVideo(
          videoId: videoId,
          title: title,
          filePath: filePath,
          size: 0,
          duration: null,
          channelName: channelName,
          thumbnailUrl: thumbnailUrl,
          downloadedAt: DateTime.now(),
          status: 'failed',
        );
        await DatabaseService.instance.addDownloadedVideo(failedVideo);
        downloadedVideosChanged.value++;
        _activeDownloads.remove(videoId);
        return null;
      }
      // Download audio stream (API updated for v2.x)
      final stream = yt.videos.streams.get(audioStreamInfo);
      final output = file.openWrite();
      int received = 0;
      final total = audioStreamInfo.size.totalBytes;
      await for (final data in stream) {
        if (_downloadCancelFlags[videoId] == true) {
          print('Download for $videoId cancelled by user.');
          await output.close();
          await file.delete().catchError((_) {});
          yt.close();
          // Remove the 'downloading' record
          await DatabaseService.instance.deleteDownloadedVideo(videoId);
          downloadedVideosChanged.value++;
          await _updateIsAnyDownloadInProgress();
          final newMap = Map<String, double>.from(downloadProgressNotifier.value);
          newMap.remove(videoId);
          downloadProgressNotifier.value = newMap;
          _downloadCancelFlags.remove(videoId);
          _activeDownloads.remove(videoId);
          return null;
        }
        output.add(data);
        received += data.length;
        if (onProgress != null) {
          onProgress(received, total);
        }
        // Update in-memory progress
        downloadProgressNotifier.value = {
          ...downloadProgressNotifier.value,
          videoId: total > 0 ? received / total : 0.0,
        };
      }
      await output.close();
      yt.close();

      // Validate file after download
      final exists = await file.exists();
      final fileSize = exists ? await file.length() : 0;
      print('Downloaded file path: $filePath');
      print('Downloaded file exists: $exists');
      print('Downloaded file size: $fileSize bytes');
      if (!exists || fileSize == 0) {
        print('Download failed or file is empty. Not adding to database.');
        // Mark as failed instead of deleting
        final failedVideo = DownloadedVideo(
          videoId: videoId,
          title: title,
          filePath: filePath,
          size: 0,
          duration: null,
          channelName: channelName,
          thumbnailUrl: thumbnailUrl,
          downloadedAt: DateTime.now(),
          status: 'failed',
        );
        await DatabaseService.instance.addDownloadedVideo(failedVideo);
        downloadedVideosChanged.value++;
        _activeDownloads.remove(videoId);
        return null;
      }

      // Update the record to 'completed'
      final completedVideo = DownloadedVideo(
        videoId: videoId,
        title: title,
        filePath: filePath,
        size: fileSize,
        duration: null,
        channelName: channelName,
        thumbnailUrl: thumbnailUrl,
        downloadedAt: DateTime.now(),
        status: 'completed',
      );
      await DatabaseService.instance.addDownloadedVideo(completedVideo);
      downloadedVideosChanged.value++;
      await _updateIsAnyDownloadInProgress();
      await NotificationService.showNotification(
        title: 'Download Complete',
        body: 'Successfully downloaded: $title',
      );
      final newMap = Map<String, double>.from(downloadProgressNotifier.value);
      newMap.remove(videoId);
      downloadProgressNotifier.value = newMap;
      _downloadCancelFlags.remove(videoId);
      _activeDownloads.remove(videoId);
      return completedVideo;
    } catch (e) {
      print('Audio download error: $e');
      yt.close();
      if (await file.exists()) {
        await file.delete();
      }
      // Mark as failed instead of deleting
      final failedVideo = DownloadedVideo(
        videoId: videoId,
        title: title,
        filePath: filePath,
        size: 0,
        duration: null,
        channelName: channelName,
        thumbnailUrl: thumbnailUrl,
        downloadedAt: DateTime.now(),
        status: 'failed',
      );
      await DatabaseService.instance.addDownloadedVideo(failedVideo);
      downloadedVideosChanged.value++;
      await _updateIsAnyDownloadInProgress();
      final newMap = Map<String, double>.from(downloadProgressNotifier.value);
      newMap.remove(videoId);
      downloadProgressNotifier.value = newMap;
      _downloadCancelFlags.remove(videoId);
      _activeDownloads.remove(videoId);
      return null;
    }
  }

  // Old method kept for compatibility if needed
  static Future<String> _downloadAudio(String audioUrl, String fileName) async {
    final response = await http.get(Uri.parse(audioUrl));
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$fileName.mp3');
    await file.writeAsBytes(response.bodyBytes);
    return file.path;
  }

  static Future<void> deleteDownloadedAudio(String videoId) async {
    if (globalPlayingNotifier.value?.videoId == videoId) {
      print('Deleting currently playing audio, stopping playback.');
      await stopGlobalAudio();
    }
    final video = await DatabaseService.instance.getDownloadedVideo(videoId);
    if (video != null) {
      final file = File(video.filePath);
      if (await file.exists()) {
        await file.delete();
      }
      final dbClient = await DatabaseService.instance.db;
      await dbClient.delete('downloaded_videos', where: 'videoId = ?', whereArgs: [videoId]);
    }
  }

  static Future<void> cancelDownload(String videoId) async {
    _downloadCancelFlags[videoId] = true;
    // Remove the in-progress record from the DB
    await DatabaseService.instance.deleteDownloadedVideo(videoId);
    downloadedVideosChanged.value++;
    await _updateIsAnyDownloadInProgress();
    // Remove progress entry
    final newMap = Map<String, double>.from(downloadProgressNotifier.value);
    newMap.remove(videoId);
    downloadProgressNotifier.value = newMap;
    // Optionally, delete the partial file
    // (You can add file deletion logic here if needed)
  }

  // Call this on app startup
  static Future<void> restoreGlobalPlayerState() async {
    final prefs = await SharedPreferences.getInstance();
    final lastVideoId = prefs.getString(_lastVideoIdKey);
    final lastPosition = prefs.getInt(_lastVideoPositionKey);
    final lastState = prefs.getString(_lastVideoStateKey);
    if (lastVideoId != null) {
      final video = await DatabaseService.instance.getDownloadedVideo(lastVideoId);
      if (video != null && File(video.filePath).existsSync()) {
        await globalAudioPlayer.setAudioSource(
          ConcatenatingAudioSource(
            children: [
              AudioSource.uri(
                Uri.file(video.filePath),
                tag: MediaItem(
                  id: video.videoId,
                  album: 'YouTube Audio',
                  title: video.title,
                  artist: video.channelName,
                  artUri: video.thumbnailUrl.isNotEmpty ? Uri.parse(video.thumbnailUrl) : null,
                ),
              ),
            ],
          ),
          initialIndex: 0,
          initialPosition: lastPosition != null && lastPosition > 0 ? Duration(milliseconds: lastPosition) : Duration.zero,
        );
        globalPlayingNotifier.value = PlayingAudio(video.videoId, lastState == 'playing');
        if (lastState == 'playing') {
          await globalAudioPlayer.play();
        }
      }
    }
  }

  // Save current playback state
  static Future<void> saveGlobalPlayerState() async {
    final prefs = await SharedPreferences.getInstance();
    final current = globalPlayingNotifier.value;
    if (current != null) {
      await prefs.setString(_lastVideoIdKey, current.videoId);
      await prefs.setInt(_lastVideoPositionKey, globalAudioPlayer.position.inMilliseconds);
      await prefs.setString(_lastVideoStateKey, globalAudioPlayer.playing ? 'playing' : 'paused');
    }
  }

  static Future<void> playOrPause(String videoId, String filePath, {String? title, String? channelName, String? thumbnailUrl}) async {
    ensureInitialized();
    final currentSource = globalAudioPlayer.audioSource;
    bool hasMediaItem = false;
    if (currentSource is ConcatenatingAudioSource &&
        currentSource.length == 1 &&
        currentSource.children.first is UriAudioSource &&
        (currentSource.children.first as UriAudioSource).tag is MediaItem) {
      final tag = (currentSource.children.first as UriAudioSource).tag as MediaItem;
      hasMediaItem = tag.id == videoId;
    }
    if (!hasMediaItem) {
      await globalAudioPlayer.setAudioSource(
        ConcatenatingAudioSource(
          children: [
            AudioSource.uri(
              Uri.file(filePath),
              tag: MediaItem(
                id: videoId,
                album: 'YouTube Audio',
                title: title ?? 'Audio',
                artist: channelName ?? '',
                artUri: thumbnailUrl != null && thumbnailUrl.isNotEmpty ? Uri.parse(thumbnailUrl) : null,
              ),
            ),
          ],
        ),
        initialIndex: 0,
        initialPosition: Duration.zero,
      );
      globalPlayingNotifier.value = PlayingAudio(videoId, false); // Set immediately after source
    }
    if (globalPlayingNotifier.value?.videoId == videoId && (globalPlayingNotifier.value?.isPlaying ?? false)) {
      await globalAudioPlayer.pause();
      globalPlayingNotifier.value = PlayingAudio(videoId, false);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('audio_position_$videoId', globalAudioPlayer.position.inMilliseconds);
      await saveGlobalPlayerState();
    } else if (globalPlayingNotifier.value?.videoId == videoId && !(globalPlayingNotifier.value?.isPlaying ?? false)) {
      globalPlayingNotifier.value = PlayingAudio(videoId, true);
      await globalAudioPlayer.play();
      await saveGlobalPlayerState();
    } else {
      await stopGlobalAudio();
      globalPlayingNotifier.value = PlayingAudio(videoId, true);
      await globalAudioPlayer.play();
      await saveGlobalPlayerState();
    }
  }

  static Future<void> _updateIsAnyDownloadInProgress() async {
    final all = await DatabaseService.instance.getDownloadedVideos();
    isAnyDownloadInProgress.value = all.any((v) => v.status == 'downloading');
  }

  // Resume any downloads that are in-progress in the DB (e.g., after navigation or app restart)
  static Future<void> resumeIncompleteDownloads() async {
    final inProgress = (await DatabaseService.instance.getDownloadedVideos())
        .where((v) => v.status == 'downloading')
        .toList();
    for (final video in inProgress) {
      if (_activeDownloads.contains(video.videoId)) {
        // Reattach progress notifier by reading file size and total size
        try {
          final dir = await getApplicationDocumentsDirectory();
          final filePath = '${dir.path}/${video.videoId}.mp3';
          final file = File(filePath);
          int received = await file.exists() ? await file.length() : 0;
          // Get total size from YouTube
          final yt = YoutubeExplode();
          final manifest = await yt.videos.streams.getManifest(video.videoId);
          final audioStreamInfo = manifest.audioOnly.withHighestBitrate();
          final total = audioStreamInfo?.size.totalBytes ?? 0;
          yt.close();
          if (total > 0) {
            final progress = received / total;
            downloadProgressNotifier.value = {
              ...downloadProgressNotifier.value,
              video.videoId: progress > 1.0 ? 1.0 : progress,
            };
          }
        } catch (e) {
          // If we can't get progress, set to 0.0
          downloadProgressNotifier.value = {
            ...downloadProgressNotifier.value,
            video.videoId: 0.0,
          };
        }
        continue;
      }
      // If not running, start/resume the download
      if (!downloadProgressNotifier.value.containsKey(video.videoId)) {
        downloadAudio(
          videoId: video.videoId,
          videoUrl: 'https://www.youtube.com/watch?v=${video.videoId}',
          title: video.title,
          channelName: video.channelName,
          thumbnailUrl: video.thumbnailUrl,
          resume: true,
        );
      }
    }
  }
} 