import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'dart:io';
import '../models/downloaded_video.dart';
import 'database_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'extractor_service.dart';
import 'yt_dlp_native_extractor.dart';
import 'youtube_explode_extractor.dart';
import 'composite_extractor.dart';

// Helper class to hold playing state
class PlayingAudio {
  final String videoId;
  final bool isPlaying;
  final String? title;
  final String? channelName;
  final String? thumbnailUrl;
  final String? filePath;
  final String? streamUrl;
  final bool isLocal;

  const PlayingAudio({
    required this.videoId,
    required this.isPlaying,
    this.title,
    this.channelName,
    this.thumbnailUrl,
    this.filePath,
    this.streamUrl,
    this.isLocal = true,
  });

  PlayingAudio copyWith({
    bool? isPlaying,
    String? title,
    String? channelName,
    String? thumbnailUrl,
    String? filePath,
    String? streamUrl,
    bool? isLocal,
  }) {
    return PlayingAudio(
      videoId: videoId,
      isPlaying: isPlaying ?? this.isPlaying,
      title: title ?? this.title,
      channelName: channelName ?? this.channelName,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      filePath: filePath ?? this.filePath,
      streamUrl: streamUrl ?? this.streamUrl,
      isLocal: isLocal ?? this.isLocal,
    );
  }
}

class DownloadService {
  // Global audio player singleton, initialized after JustAudioBackground.init
  static late final AudioPlayer globalAudioPlayer;
  static bool _audioPlayerInitialized = false;
  // Global notifier for currently playing videoId and playing state
  static final ValueNotifier<PlayingAudio?> globalPlayingNotifier =
      ValueNotifier<PlayingAudio?>(null);
  static final ValueNotifier<bool> globalSessionActive =
      ValueNotifier<bool>(false);
  static final ValueNotifier<int> downloadedVideosChanged = ValueNotifier<int>(
    0,
  );
  static final ValueNotifier<Map<String, double>> downloadProgressNotifier =
      ValueNotifier({});
  static final ValueNotifier<bool> isAnyDownloadInProgress =
      ValueNotifier<bool>(false);
  static final Map<String, bool> _downloadCancelFlags = {};
  static final Set<String> _activeDownloads = {};
  static final Set<String> _recentlyCancelledDownloads = {};
  static const int _maxDownloadRetries = 3;
  static const String _downloadUserAgent =
      'Mozilla/5.0 (Linux; Android 13; en-us) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';
  static const Map<String, String> _downloadRequestHeaders = {
    'Connection': 'keep-alive',
    'Accept': '*/*',
  };
  static final ExtractorService _extractor = CompositeExtractor(
    NativeYtDlpExtractor(),
    YoutubeExplodeExtractor(),
  );
  static const MethodChannel _foregroundChannel =
      MethodChannel('download_foreground_service');
  static bool _isForegroundServiceActive = false;

  static int? _parseTotalFromContentRange(String? contentRange) {
    if (contentRange == null || contentRange.isEmpty) return null;
    final match = RegExp(r'bytes\s+\d+-\d+/(\d+|\*)', caseSensitive: false)
        .firstMatch(contentRange);
    if (match == null) return null;
    final totalPart = match.group(1);
    if (totalPart == null || totalPart == '*') return null;
    return int.tryParse(totalPart);
  }

  static void _updateProgressState(
    String videoId,
    int receivedBytes,
    int totalBytes,
  ) {
    if (totalBytes <= 0) return;
    final progressValue =
        (receivedBytes / totalBytes).clamp(0.0, 1.0).toDouble();
    final previous = downloadProgressNotifier.value[videoId] ?? 0.0;
    if ((progressValue - previous).abs() >= 0.01 || progressValue >= 0.999) {
      downloadProgressNotifier.value = {
        ...downloadProgressNotifier.value,
        videoId: progressValue,
      };
    }
  }

  static Future<int?> _getRemoteContentLength(String url) async {
    try {
      final response = await http.head(
        Uri.parse(url),
        headers: {
          ..._downloadRequestHeaders,
          'User-Agent': _downloadUserAgent,
        },
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      final headerValue = response.headers['content-length'];
      final directLength = headerValue != null ? int.tryParse(headerValue) : 0;
      if (directLength != null && directLength > 0) {
        return directLength;
      }
      return _parseTotalFromContentRange(response.headers['content-range']);
    } catch (_) {
      return null;
    }
  }

  static Future<void> _ensureForegroundServiceActive() async {
    if (!Platform.isAndroid) return;
    if (_isForegroundServiceActive) return;
    try {
      await _foregroundChannel.invokeMethod('start');
      _isForegroundServiceActive = true;
    } catch (e) {
      debugPrint('Failed to start foreground service: $e');
    }
  }

  static Future<void> _stopForegroundServiceIfIdle() async {
    if (!Platform.isAndroid) return;
    if (_activeDownloads.isNotEmpty) return;
    if (!_isForegroundServiceActive) return;
    try {
      await _foregroundChannel.invokeMethod('stop');
    } catch (e) {
      debugPrint('Failed to stop foreground service: $e');
    } finally {
      _isForegroundServiceActive = false;
    }
  }

  static Future<void> _handleDownloadRemoved(String videoId) async {
    _activeDownloads.remove(videoId);
    await _stopForegroundServiceIfIdle();
  }

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
  static const String _sessionActiveKey = 'global_session_active';
  static bool _hasActiveSession = false;

  static void ensureInitialized() {
    if (_initialized) return;
    _initialized = true;
    globalPlayingNotifier.addListener(_updateMiniPlayerVisibility);
    globalAudioPlayer.playerStateStream.listen((state) {
      final current = globalPlayingNotifier.value;
      if (state.processingState == ProcessingState.completed ||
          state.processingState == ProcessingState.idle) {
        globalPlayingNotifier.value = null;
      } else if (state.playing) {
        if (current != null) {
          globalPlayingNotifier.value = current.copyWith(isPlaying: true);
        }
      } else {
        if (current != null) {
          globalPlayingNotifier.value = current.copyWith(isPlaying: false);
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
    if (!_audioPlayerInitialized) return;
    try {
      await globalAudioPlayer.stop();
    } catch (_) {}
    if (globalPlayingNotifier.value != null) {
      globalPlayingNotifier.value = null;
    }
    await saveGlobalPlayerState();
  }

  @pragma('vm:entry-point')
  static Future<bool> isVideoDownloaded(String videoId) async {
    final video = await DatabaseService.instance.getDownloadedVideo(videoId);
    if (video == null) return false;
    if (video.status != 'completed') return false;
    return File(video.filePath).existsSync();
  }

  @pragma('vm:entry-point')
  static Future<String?> getDownloadedFilePath(String videoId) async {
    final video = await DatabaseService.instance.getDownloadedVideo(videoId);
    if (video == null || video.status != 'completed') return null;
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
    await _ensureForegroundServiceActive();
    final dir = await getApplicationDocumentsDirectory();
    final filePath = '${dir.path}/$videoId.mp3';
    final file = File(filePath);
    // Delete any old .m4a file for this videoId
    final oldM4a = File('${dir.path}/$videoId.m4a');
    if (await oldM4a.exists()) {
      await oldM4a.delete();
    }
    _downloadCancelFlags[videoId] = false;
    _recentlyCancelledDownloads.remove(videoId);
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
    http.Client? client;
    HttpClient? ioHttpClient;
    try {
      final sourceIdOrUrl = videoUrl.isNotEmpty
          ? videoUrl
          : 'https://www.youtube.com/watch?v=$videoId';
      final extracted = await _extractor.getBestAudio(sourceIdOrUrl);
      int fileSize = 0;
      int attempt = 0;
      bool shouldAttemptResume = resume;
      int? knownRemoteLength;
      while (attempt < _maxDownloadRetries) {
        IOSink? output;
        try {
          final fileExists = await file.exists();
          final existingLength = fileExists ? await file.length() : 0;
          if (!shouldAttemptResume && existingLength > 0) {
            shouldAttemptResume = true;
          }
          final bool resumeThisAttempt =
              shouldAttemptResume && existingLength > 0;

          if (resumeThisAttempt && knownRemoteLength == null) {
            knownRemoteLength = await _getRemoteContentLength(extracted.url);
            if (knownRemoteLength != null &&
                existingLength >= knownRemoteLength) {
              fileSize = existingLength;
              break;
            }
            if (knownRemoteLength != null) {
              onProgress?.call(existingLength, knownRemoteLength);
              _updateProgressState(videoId, existingLength, knownRemoteLength);
            }
          }

          if (!resumeThisAttempt && fileExists) {
            await file.delete();
          }
          ioHttpClient = HttpClient()
            ..userAgent = _downloadUserAgent
            ..connectionTimeout = const Duration(seconds: 20)
            ..autoUncompress = false
            ..maxConnectionsPerHost = 8;
          client = IOClient(ioHttpClient);
          final request = http.Request('GET', Uri.parse(extracted.url));
          final requestHeaders = Map<String, String>.from(
            _downloadRequestHeaders,
          );
          if (resumeThisAttempt && existingLength > 0) {
            requestHeaders['Range'] = 'bytes=$existingLength-';
          }
          request.headers.addAll(requestHeaders);
          final response = await client.send(request);

          if (resumeThisAttempt && response.statusCode == 416) {
            knownRemoteLength ??=
                _parseTotalFromContentRange(response.headers['content-range']);
            final currentSize = await file.length();
            if (knownRemoteLength != null &&
                currentSize >= knownRemoteLength) {
              fileSize = currentSize;
              break;
            }
            shouldAttemptResume = false;
            if (fileExists) {
              await file.delete();
            }
            throw Exception(
              'Resume rejected with status 416 for $videoId',
            );
          }

          if (resumeThisAttempt &&
              response.statusCode == 200 &&
              existingLength > 0) {
            shouldAttemptResume = false;
            await response.stream.drain();
            if (await file.exists()) {
              await file.delete();
            }
            continue;
          }

          if (response.statusCode < 200 || response.statusCode >= 300) {
            throw Exception(
              'Audio download failed with status ${response.statusCode}',
            );
          }

          knownRemoteLength ??=
              _parseTotalFromContentRange(response.headers['content-range']);
          if (knownRemoteLength == null) {
            final responseLength = response.contentLength ?? 0;
            if (responseLength > 0) {
              if (resumeThisAttempt && response.statusCode == 206) {
                knownRemoteLength = existingLength + responseLength;
              } else {
                knownRemoteLength = responseLength;
              }
            }
          }
          if (resumeThisAttempt && knownRemoteLength != null) {
            _updateProgressState(videoId, existingLength, knownRemoteLength);
          }

          output = file.openWrite(
            mode: resumeThisAttempt ? FileMode.append : FileMode.write,
          );
          int received = resumeThisAttempt ? existingLength : 0;
          final totalForCallbacks = knownRemoteLength ?? 0;
          if (onProgress != null) {
            onProgress(received, totalForCallbacks);
          }

          await for (final data in response.stream) {
            if (_downloadCancelFlags[videoId] == true) {
              print('Download for $videoId cancelled by user.');
              await output.close();
              try {
                await file.delete();
              } catch (_) {}
              _recentlyCancelledDownloads.add(videoId);
              await DatabaseService.instance.deleteDownloadedVideo(videoId);
              downloadedVideosChanged.value++;
              await _updateIsAnyDownloadInProgress();
              final newMap = Map<String, double>.from(
                downloadProgressNotifier.value,
              );
              newMap.remove(videoId);
              downloadProgressNotifier.value = newMap;
              _downloadCancelFlags.remove(videoId);
              await _handleDownloadRemoved(videoId);
              return null;
            }
            output.add(data);
            received += data.length;
            if (onProgress != null) {
              onProgress(received, totalForCallbacks);
            }
            if (knownRemoteLength != null) {
              _updateProgressState(videoId, received, knownRemoteLength);
            }
          }

          await output.close();
          fileSize = await file.length();
          if (knownRemoteLength != null) {
            final expectedSize = knownRemoteLength;
            if (fileSize < expectedSize && (expectedSize - fileSize) > 5) {
              throw Exception(
                'Downloaded size $fileSize is less than expected $expectedSize',
              );
            }
          }
          if (fileSize == 0) {
            throw Exception('Downloaded file is empty');
          }
          break;
        } catch (e) {
          print('Download attempt ${attempt + 1} for $videoId failed: $e');
          await output?.close();
          if (_downloadCancelFlags[videoId] == true) {
            _recentlyCancelledDownloads.add(videoId);
            await DatabaseService.instance.deleteDownloadedVideo(videoId);
            downloadedVideosChanged.value++;
            await _updateIsAnyDownloadInProgress();
            final newMap = Map<String, double>.from(
              downloadProgressNotifier.value,
            );
            newMap.remove(videoId);
            downloadProgressNotifier.value = newMap;
            _downloadCancelFlags.remove(videoId);
            await _handleDownloadRemoved(videoId);
            return null;
          }
          if (await file.exists()) {
            final partialSize = await file.length();
            if (partialSize > 0) {
              shouldAttemptResume = true;
              final total = knownRemoteLength;
              if (total != null) {
                _updateProgressState(videoId, partialSize, total);
              }
            }
          }
          if (++attempt >= _maxDownloadRetries) {
            rethrow;
          }
          await Future.delayed(Duration(seconds: 2 * attempt));
        } finally {
          client?.close();
          ioHttpClient?.close(force: true);
          client = null;
          ioHttpClient = null;
        }
      }

      final exists = await file.exists();
      print('Downloaded file path: $filePath');
      print('Downloaded file exists: $exists');
      print('Downloaded file size: ${exists ? fileSize : 0} bytes');
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
        await _handleDownloadRemoved(videoId);
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
      await _handleDownloadRemoved(videoId);
      return completedVideo;
    } catch (e) {
      print('Audio download error: $e');
      final wasCancelled =
          _downloadCancelFlags[videoId] == true ||
          _recentlyCancelledDownloads.contains(videoId);
      try {
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
      if (wasCancelled) {
        _recentlyCancelledDownloads.remove(videoId);
        _downloadCancelFlags.remove(videoId);
        final newMap = Map<String, double>.from(
          downloadProgressNotifier.value,
        );
        newMap.remove(videoId);
        downloadProgressNotifier.value = newMap;
        await _handleDownloadRemoved(videoId);
        await _updateIsAnyDownloadInProgress();
        client?.close();
        ioHttpClient?.close(force: true);
        return null;
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
      _recentlyCancelledDownloads.remove(videoId);
      await _handleDownloadRemoved(videoId);
      client?.close();
      ioHttpClient?.close(force: true);
      return null;
    }
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
      await dbClient.delete(
        'downloaded_videos',
        where: 'videoId = ?',
        whereArgs: [videoId],
      );
    }
  }

  static Future<void> cancelDownload(String videoId) async {
    _downloadCancelFlags[videoId] = true;
    _recentlyCancelledDownloads.add(videoId);
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

  static bool consumeCancelledFlag(String videoId) {
    return _recentlyCancelledDownloads.remove(videoId);
  }

  static bool get hasActiveSession => _hasActiveSession;

  static bool shouldShowMiniPlayer({
    PlayingAudio? playing,
    bool? sessionActive,
  }) {
    final session = sessionActive ?? _hasActiveSession;
    if (!session) return false;
    playing ??= globalPlayingNotifier.value;
    if (playing != null) {
      return true;
    }
    if (!_audioPlayerInitialized) {
      return false;
    }
    final state = globalAudioPlayer.playerState;
    if (state.playing) return true;
    if (state.processingState == ProcessingState.buffering) return true;
    return false;
  }

  static Future<void> clearPlaybackSession() async {
    ensureInitialized();
    final closingVideoId = globalPlayingNotifier.value?.videoId;
    await stopGlobalAudio();
    await _setSessionActive(false, closingVideoId: closingVideoId);
    globalPlayingNotifier.value = null;
  }

  static Future<void> _setSessionActive(
    bool active, {
    String? closingVideoId,
  }) async {
    if (_hasActiveSession == active) return;
    _hasActiveSession = active;
    globalSessionActive.value = active;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_sessionActiveKey, active);
    if (!active) {
      await prefs.remove(_lastVideoIdKey);
      await prefs.remove(_lastVideoPositionKey);
      await prefs.remove(_lastVideoStateKey);
      if (closingVideoId != null) {
        await prefs.remove('audio_position_$closingVideoId');
      }
    }
  }

  static void _updateMiniPlayerVisibility() {
    if (_hasActiveSession && !globalSessionActive.value) {
      globalSessionActive.value = true;
    }
  }

  // Call this on app startup
  static Future<void> restoreGlobalPlayerState() async {
    final prefs = await SharedPreferences.getInstance();
    final storedSessionActive = prefs.getBool(_sessionActiveKey) ?? false;
    _hasActiveSession = storedSessionActive;
    globalSessionActive.value = storedSessionActive;
    if (!storedSessionActive) {
      return;
    }
    final lastVideoId = prefs.getString(_lastVideoIdKey);
    final lastPosition = prefs.getInt(_lastVideoPositionKey);
    final lastState = prefs.getString(_lastVideoStateKey);
    if (lastVideoId != null) {
      final video = await DatabaseService.instance.getDownloadedVideo(
        lastVideoId,
      );
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
                  artUri: video.thumbnailUrl.isNotEmpty
                      ? Uri.parse(video.thumbnailUrl)
                      : null,
                ),
              ),
            ],
          ),
          initialIndex: 0,
          initialPosition: lastPosition != null && lastPosition > 0
              ? Duration(milliseconds: lastPosition)
              : Duration.zero,
        );
        globalPlayingNotifier.value = PlayingAudio(
          videoId: video.videoId,
          isPlaying: lastState == 'playing',
          title: video.title,
          channelName: video.channelName,
          thumbnailUrl: video.thumbnailUrl,
          filePath: video.filePath,
          isLocal: true,
        );
        await _setSessionActive(true);
        if (lastState == 'playing') {
          await globalAudioPlayer.play();
        }
      } else {
        await _setSessionActive(false);
      }
    } else {
      await _setSessionActive(false);
    }
  }

  // Save current playback state
  static Future<void> saveGlobalPlayerState() async {
    final prefs = await SharedPreferences.getInstance();
    final current = globalPlayingNotifier.value;
    if (current != null) {
      await prefs.setString(_lastVideoIdKey, current.videoId);
      await prefs.setInt(
        _lastVideoPositionKey,
        globalAudioPlayer.position.inMilliseconds,
      );
      await prefs.setString(
        _lastVideoStateKey,
        globalAudioPlayer.playing ? 'playing' : 'paused',
      );
      await prefs.setBool(_sessionActiveKey, true);
    }
  }

  static Future<void> playOrPause(
    String videoId,
    String filePath, {
    String? title,
    String? channelName,
    String? thumbnailUrl,
  }) async {
    ensureInitialized();
    final current = globalPlayingNotifier.value;
    final isSameLocal =
        current?.videoId == videoId && (current?.isLocal ?? false);

    if (isSameLocal) {
      if (current?.isPlaying ?? false) {
        await globalAudioPlayer.pause();
        globalPlayingNotifier.value = current!.copyWith(isPlaying: false);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(
          'audio_position_$videoId',
          globalAudioPlayer.position.inMilliseconds,
        );
      } else {
        await globalAudioPlayer.play();
        globalPlayingNotifier.value = current!.copyWith(isPlaying: true);
      }
      await saveGlobalPlayerState();
      return;
    }

    await stopGlobalAudio();

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
              artUri: thumbnailUrl != null && thumbnailUrl.isNotEmpty
                  ? Uri.parse(thumbnailUrl)
                  : null,
            ),
          ),
        ],
      ),
      initialIndex: 0,
      initialPosition: Duration.zero,
    );

    final playing = PlayingAudio(
      videoId: videoId,
      isPlaying: true,
      title: title,
      channelName: channelName,
      thumbnailUrl: thumbnailUrl,
      filePath: filePath,
      isLocal: true,
    );
    globalPlayingNotifier.value = playing;
    await _setSessionActive(true);
    await globalAudioPlayer.play();
    await saveGlobalPlayerState();
  }

  static Future<void> playStream({
    required String videoId,
    required String videoUrl,
    String? title,
    String? channelName,
    String? thumbnailUrl,
  }) async {
    ensureInitialized();
    final current = globalPlayingNotifier.value;
    final isSameStream =
        current?.videoId == videoId && !(current?.isLocal ?? true);

    if (isSameStream) {
      if (current?.isPlaying ?? false) {
        await globalAudioPlayer.pause();
        globalPlayingNotifier.value = current!.copyWith(isPlaying: false);
      } else {
        await globalAudioPlayer.play();
        globalPlayingNotifier.value = current!.copyWith(isPlaying: true);
      }
      await saveGlobalPlayerState();
      return;
    }

    await stopGlobalAudio();

    final extracted = await _extractor.getBestAudio(videoUrl);

    await globalAudioPlayer.setAudioSource(
      AudioSource.uri(
        Uri.parse(extracted.url),
        tag: MediaItem(
          id: videoId,
          album: 'YouTube Audio',
          title: title ?? 'Audio',
          artist: channelName ?? '',
          artUri:
              thumbnailUrl != null && thumbnailUrl.isNotEmpty ? Uri.parse(thumbnailUrl) : null,
        ),
      ),
    );

    final playing = PlayingAudio(
      videoId: videoId,
      isPlaying: true,
      title: title,
      channelName: channelName,
      thumbnailUrl: thumbnailUrl,
      streamUrl: extracted.url,
      isLocal: false,
    );

    globalPlayingNotifier.value = playing;
    await _setSessionActive(true);
    await globalAudioPlayer.play();
    await saveGlobalPlayerState();
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
    if (inProgress.isNotEmpty) {
      await _ensureForegroundServiceActive();
    }
    for (final video in inProgress) {
      if (_activeDownloads.contains(video.videoId)) {
        // Reattach progress notifier by reading file size and total size
        try {
          final dir = await getApplicationDocumentsDirectory();
          final filePath = '${dir.path}/${video.videoId}.mp3';
          final file = File(filePath);
          final received = await file.exists() ? await file.length() : 0;

          final extracted = await _extractor.getBestAudio(
            'https://www.youtube.com/watch?v=${video.videoId}',
          );
          final total = await _getRemoteContentLength(extracted.url);

          if (total != null && total > 0) {
            _updateProgressState(video.videoId, received, total);
          } else {
            downloadProgressNotifier.value = {
              ...downloadProgressNotifier.value,
              video.videoId: 0.0,
            };
          }
        } catch (e) {
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
