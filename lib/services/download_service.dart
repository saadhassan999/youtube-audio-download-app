import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/snackbar_bus.dart';
import '../models/downloaded_video.dart';
import '../models/video.dart';
import '../repositories/video_repository.dart';
import 'composite_extractor.dart';
import 'database_service.dart';
import 'extractor_service.dart';
import 'notification_service.dart';
import 'youtube_explode_extractor.dart';
import 'yt_dlp_native_extractor.dart';

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
  static final ValueNotifier<bool> globalSessionActive = ValueNotifier<bool>(
    false,
  );
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
  static const int _minValidDownloadBytes = 200 * 1024; // 200 KiB guardrail
  static final ExtractorService _streamExtractor = CompositeExtractor(
    const NativeYtDlpExtractor(forDownload: false),
    YoutubeExplodeExtractor(),
    primaryTimeout: const Duration(seconds: 60),
    runFallbackInIsolate: true,
  );
  static final ExtractorService _downloadExtractor = CompositeExtractor(
    const NativeYtDlpExtractor(forDownload: true),
    YoutubeExplodeExtractor(),
    primaryTimeout: const Duration(seconds: 60),
    runFallbackInIsolate: true,
  );
  static const MethodChannel _foregroundChannel = MethodChannel(
    'download_foreground_service',
  );
  static bool _isForegroundServiceActive = false;

  static void _log(String message) {
    debugPrint('[DownloadService] $message');
  }

  static bool _looksLikeManifestUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('manifest.googlevideo.com') ||
        lower.contains('.m3u8') ||
        lower.contains('playlist.m3u8') ||
        lower.contains('mime=application%2fx-mpegurl');
  }

  static String _guessExtension(String? mimeType, String? container) {
    final mime = mimeType?.toLowerCase() ?? '';
    final c = container?.toLowerCase() ?? '';
    if (mime.startsWith('audio/mp4') || c == 'm4a' || c == 'mp4') {
      return 'm4a';
    }
    if (mime.startsWith('audio/webm') || c == 'webm' || c == 'weba') {
      return 'webm';
    }
    if (mime.startsWith('audio/mpeg') || c == 'mp3') {
      return 'mp3';
    }
    return 'm4a';
  }

  static Future<bool> _isLikelyCorruptFile(File file) async {
    try {
      final raf = await file.open();
      final header = await raf.read(16);
      await raf.close();
      if (header.isEmpty) return true;
      final headerString = String.fromCharCodes(header);
      return headerString.startsWith('#EXTM3U') ||
          headerString.startsWith('<!DOCTYPE') ||
          headerString.startsWith('<html');
    } catch (_) {
      return true;
    }
  }

  static int? _parseTotalFromContentRange(String? contentRange) {
    if (contentRange == null || contentRange.isEmpty) return null;
    final match = RegExp(
      r'bytes\s+\d+-\d+/(\d+|\*)',
      caseSensitive: false,
    ).firstMatch(contentRange);
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
    final progressValue = (receivedBytes / totalBytes)
        .clamp(0.0, 1.0)
        .toDouble();
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
        headers: {..._downloadRequestHeaders, 'User-Agent': _downloadUserAgent},
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
  static final Map<String, int> _lastPersistedPositionMs = {};
  static const int _positionPersistIntervalMs = 500;
  static const Duration _skipInterval = Duration(seconds: 10);
  static const Duration _seekDebounceEpsilon = Duration(milliseconds: 250);
  static bool _isSeekInFlight = false;
  static Duration? _pendingSeekTarget;

  static void ensureInitialized() {
    if (_initialized) return;
    _initialized = true;
    globalPlayingNotifier.addListener(_updateMiniPlayerVisibility);
    globalAudioPlayer.playerStateStream.listen((state) {
      final current = globalPlayingNotifier.value;
      _log(
        'playerState update: processing=${state.processingState}, playing=${state.playing}',
      );

      if (state.processingState == ProcessingState.idle &&
          current?.isLocal == true) {
        final filePath = current?.filePath;
        final missing = filePath == null || !File(filePath).existsSync();
        if (missing) {
          _log('missing local file detected for ${current?.videoId}');
          showGlobalSnackBarMessage(
            'File not found. Stream or re-download to play.',
          );
          unawaited(clearPlaybackSession());
          return;
        }
      }

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
    if (video == null || video.status != 'completed') return false;
    return await File(video.filePath).exists();
  }

  @pragma('vm:entry-point')
  static Future<String?> getDownloadedFilePath(String videoId) async {
    final video = await DatabaseService.instance.getDownloadedVideo(videoId);
    if (video == null || video.status != 'completed') return null;
    return await File(video.filePath).exists() ? video.filePath : null;
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
    final existingVariants = [
      File('${dir.path}/$videoId.m4a'),
      File('${dir.path}/$videoId.webm'),
      File('${dir.path}/$videoId.mp3'),
    ];
    if (!resume) {
      for (final f in existingVariants) {
        if (await f.exists()) {
          await f.delete();
        }
      }
    }
    String filePath = '${dir.path}/$videoId.tmp';
    String chosenExtension = 'tmp';
    File file = File(filePath);
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
      final extractSw = Stopwatch()..start();
      final extracted = await _downloadExtractor.getBestAudio(sourceIdOrUrl);
      final extractedHost = Uri.tryParse(extracted.url)?.host ?? 'unknown';
      _log(
        'Extraction $videoId took ${extractSw.elapsedMilliseconds}ms (host=$extractedHost)',
      );
      if (_looksLikeManifestUrl(extracted.url)) {
        throw Exception(
          'Download extractor returned manifest URL for $videoId ($extractedHost)',
        );
      }
      chosenExtension = _guessExtension(extracted.mimeType, extracted.container);
      _log(
        'Download URL for $videoId host=$extractedHost mime=${extracted.mimeType} ext=${extracted.container ?? chosenExtension}',
      );
      filePath = '${dir.path}/$videoId.$chosenExtension';
      file = File(filePath);
      if (resume && !await file.exists()) {
        // Try to resume from any existing variant if present
        for (final candidate in existingVariants) {
          if (await candidate.exists()) {
            file = candidate;
            filePath = candidate.path;
            chosenExtension = candidate.uri.pathSegments.last.split('.').last;
            break;
          }
        }
      }
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
            knownRemoteLength ??= _parseTotalFromContentRange(
              response.headers['content-range'],
            );
            final currentSize = await file.length();
            if (knownRemoteLength != null && currentSize >= knownRemoteLength) {
              fileSize = currentSize;
              break;
            }
            shouldAttemptResume = false;
            if (fileExists) {
              await file.delete();
            }
            throw Exception('Resume rejected with status 416 for $videoId');
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

          knownRemoteLength ??= _parseTotalFromContentRange(
            response.headers['content-range'],
          );
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
          final throughputSw = Stopwatch()..start();
          int lastLoggedBytes = received;

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
            if (throughputSw.elapsedMilliseconds >= 2000) {
              final deltaBytes = received - lastLoggedBytes;
              final seconds = throughputSw.elapsedMilliseconds / 1000;
              if (seconds > 0) {
                final mbps = (deltaBytes * 8) / seconds / 1e6;
                _log(
                  'Speed $videoId: ${mbps.toStringAsFixed(2)} Mbps, downloaded ${received ~/ 1024} KiB',
                );
              }
              throughputSw.reset();
              lastLoggedBytes = received;
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
      if (fileSize < _minValidDownloadBytes ||
          await _isLikelyCorruptFile(file)) {
        _log(
          'Downloaded content for $videoId looks invalid (size=$fileSize); marking as failed',
        );
        try {
          await file.delete();
        } catch (_) {}
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
        final newMap = Map<String, double>.from(downloadProgressNotifier.value);
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

  static Future<DownloadedVideo?> downloadVideo(
    Video video, {
    bool trackSavedVideo = false,
  }) async {
    ensureInitialized();
    final videoId = video.id;
    final alreadyDownloading = _activeDownloads.contains(videoId);

    if (trackSavedVideo) {
      await VideoRepository.instance.markSavedVideoAsDownloading(
        videoId,
        bytesDownloaded: 0,
      );
    }

    DownloadedVideo? result;
    try {
      result = await downloadAudio(
        videoId: video.id,
        videoUrl: 'https://www.youtube.com/watch?v=${video.id}',
        title: video.title,
        channelName: video.channelName,
        thumbnailUrl: video.thumbnailUrl,
        onProgress: (received, total) {
          if (!trackSavedVideo) return;
          final totalValue = total > 0 ? total : null;
          unawaited(
            VideoRepository.instance.updateSavedVideoProgress(
              videoId,
              bytesDownloaded: received,
              bytesTotal: totalValue,
            ),
          );
        },
      );
    } catch (e) {
      if (trackSavedVideo) {
        await VideoRepository.instance.markSavedVideoAsError(videoId);
      }
      rethrow;
    }

    if (!trackSavedVideo) {
      return result;
    }

    final wasCancelled = consumeCancelledFlag(videoId);

    if (result != null) {
      await VideoRepository.instance.markSavedVideoAsDownloaded(
        videoId,
        result.filePath,
        result.size,
      );
    } else if (wasCancelled) {
      await VideoRepository.instance.resetSavedVideo(videoId);
    } else if (!alreadyDownloading) {
      await VideoRepository.instance.markSavedVideoAsError(videoId);
    }

    return result;
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
      await DatabaseService.instance.deleteDownloadedVideo(videoId);
    }
    // Reflect deletion everywhere: clear saved-video download status and notify listeners.
    await VideoRepository.instance.resetSavedVideo(videoId);
    downloadedVideosChanged.value++;
    await _updateIsAnyDownloadInProgress();
    // Remove any stale progress entry.
    final newMap = Map<String, double>.from(downloadProgressNotifier.value);
    newMap.remove(videoId);
    downloadProgressNotifier.value = newMap;
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
        _lastPersistedPositionMs.remove(closingVideoId);
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
        _lastPersistedPositionMs[video.videoId] =
            lastPosition ?? video.duration?.inMilliseconds ?? 0;
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
      final positionMs = globalAudioPlayer.position.inMilliseconds;
      await prefs.setString(_lastVideoIdKey, current.videoId);
      await prefs.setInt(_lastVideoPositionKey, positionMs);
      await prefs.setString(
        _lastVideoStateKey,
        globalAudioPlayer.playing ? 'playing' : 'paused',
      );
      await prefs.setBool(_sessionActiveKey, true);
      if (current.isLocal) {
        final lastPersisted =
            _lastPersistedPositionMs[current.videoId] ??
            -_positionPersistIntervalMs;
        if ((positionMs - lastPersisted).abs() >= _positionPersistIntervalMs ||
            !prefs.containsKey('audio_position_${current.videoId}')) {
          await prefs.setInt('audio_position_${current.videoId}', positionMs);
          _lastPersistedPositionMs[current.videoId] = positionMs;
        }
      }
    }
  }

  static Duration _clampPosition(Duration target, Duration? duration) {
    if (target < Duration.zero) return Duration.zero;
    if (duration != null && duration > Duration.zero && target > duration) {
      return duration;
    }
    return target;
  }

  static Future<Duration?> seekRelative(Duration offset) async {
    ensureInitialized();
    final position = globalAudioPlayer.position;
    final duration = globalAudioPlayer.duration;
    final target = _clampPosition(position + offset, duration);
    if ((target - position).abs() < _seekDebounceEpsilon) {
      return target;
    }
    return _enqueueSeek(target);
  }

  static Duration get skipInterval => _skipInterval;

  static Future<Duration?> _enqueueSeek(Duration target) async {
    if (_isSeekInFlight) {
      _pendingSeekTarget = target;
      return target;
    }
    _isSeekInFlight = true;
    Duration? result = target;
    try {
      await globalAudioPlayer.seek(target);
      final current = globalPlayingNotifier.value;
      if (current != null) {
        _lastPersistedPositionMs[current.videoId] = target.inMilliseconds;
      }
      await saveGlobalPlayerState();
    } finally {
      _isSeekInFlight = false;
      final pending = _pendingSeekTarget;
      if (pending != null && (pending - target).abs() >= _seekDebounceEpsilon) {
        _pendingSeekTarget = null;
        result = await _enqueueSeek(pending);
      } else {
        _pendingSeekTarget = null;
      }
    }
    return result;
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
        _log('toggle pause (local) $videoId');
        await globalAudioPlayer.pause();
        globalPlayingNotifier.value = current!.copyWith(isPlaying: false);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(
          'audio_position_$videoId',
          globalAudioPlayer.position.inMilliseconds,
        );
      } else {
        _log('toggle resume (local) $videoId');
        await globalAudioPlayer.play();
        globalPlayingNotifier.value = current!.copyWith(isPlaying: true);
      }
      await saveGlobalPlayerState();
      return;
    }

    await stopGlobalAudio();

    _log('setAudioSource(local): $filePath');
    try {
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
    } catch (e) {
      _log('setAudioSource(local) failed for $videoId at $filePath: $e');
      await _handleCorruptLocalPlayback(
        videoId,
        filePath,
        title: title,
        channelName: channelName,
        thumbnailUrl: thumbnailUrl,
      );
      return;
    }

    final playing = PlayingAudio(
      videoId: videoId,
      isPlaying: true,
      title: title,
      channelName: channelName,
      thumbnailUrl: thumbnailUrl,
      filePath: filePath,
      isLocal: true,
    );
    _lastPersistedPositionMs[videoId] = 0;
    globalPlayingNotifier.value = playing;
    await _setSessionActive(true);
    try {
      await globalAudioPlayer.play();
    } catch (e) {
      _log('play local failed for $videoId: $e');
      await _handleCorruptLocalPlayback(
        videoId,
        filePath,
        title: title,
        channelName: channelName,
        thumbnailUrl: thumbnailUrl,
      );
      return;
    }
    _log('play local $videoId');
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
        _log('toggle pause (stream) $videoId');
        await globalAudioPlayer.pause();
        globalPlayingNotifier.value = current!.copyWith(isPlaying: false);
      } else {
        _log('toggle resume (stream) $videoId');
        await globalAudioPlayer.play();
        globalPlayingNotifier.value = current!.copyWith(isPlaying: true);
      }
      await saveGlobalPlayerState();
      return;
    }

    _log('prepare stream playback for $videoId');
    await stopGlobalAudio();

    final extractSw = Stopwatch()..start();
    final extracted = await _streamExtractor.getBestAudio(videoUrl);
    final extractedHost = Uri.tryParse(extracted.url)?.host ?? 'unknown';
    _log(
      'Extraction $videoId took ${extractSw.elapsedMilliseconds}ms (host=$extractedHost)',
    );

    _log('setAudioSource(stream): ${extracted.url}');
    final setSourceSw = Stopwatch()..start();
    await globalAudioPlayer.setAudioSource(
      AudioSource.uri(
        Uri.parse(extracted.url),
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
    );
    _log('setAudioSource $videoId took ${setSourceSw.elapsedMilliseconds}ms');

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
    final playSw = Stopwatch()..start();
    await globalAudioPlayer.play();
    _log('play() $videoId returned in ${playSw.elapsedMilliseconds}ms');
    _log('play stream $videoId');
    await saveGlobalPlayerState();
  }

  static Future<void> _handleCorruptLocalPlayback(
    String videoId,
    String filePath, {
    String? title,
    String? channelName,
    String? thumbnailUrl,
  }) async {
    _log(
      'local playback failed for $videoId at $filePath; deleting file and marking as corrupt',
    );
    try {
      final f = File(filePath);
      if (await f.exists()) {
        await f.delete();
      }
    } catch (_) {}
    await DatabaseService.instance.deleteDownloadedVideo(videoId);
    downloadedVideosChanged.value++;
    await _updateIsAnyDownloadInProgress();
    showGlobalSnackBarMessage(
      'Download looks corrupted. Please re-download this audio.',
    );
  }

  static Future<void> togglePlayback() async {
    ensureInitialized();
    final playing = globalPlayingNotifier.value;
    if (playing == null) {
      _log('togglePlayback called with no active track');
      return;
    }

    if (playing.isLocal) {
      final filePath = playing.filePath;
      if (filePath == null || filePath.isEmpty) {
        _log('togglePlayback local path missing for ${playing.videoId}');
        await clearPlaybackSession();
        throw const FileSystemException('File not found');
      }

      final file = File(filePath);
      if (!await file.exists()) {
        _log('togglePlayback local file missing for ${playing.videoId}');
        await clearPlaybackSession();
        throw FileSystemException('File not found', filePath);
      }

      _log('togglePlayback delegating to playOrPause for ${playing.videoId}');
      await playOrPause(
        playing.videoId,
        filePath,
        title: playing.title,
        channelName: playing.channelName,
        thumbnailUrl: playing.thumbnailUrl,
      );
      return;
    }

    if (globalAudioPlayer.playing) {
      _log('toggle pause (stream) ${playing.videoId}');
      await globalAudioPlayer.pause();
      final current = globalPlayingNotifier.value;
      if (current != null) {
        globalPlayingNotifier.value = current.copyWith(isPlaying: false);
      }
    } else {
      _log('toggle resume (stream) ${playing.videoId}');
      await globalAudioPlayer.play();
      final current = globalPlayingNotifier.value;
      if (current != null) {
        globalPlayingNotifier.value = current.copyWith(isPlaying: true);
      }
    }
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
          final candidates = [
            File('${dir.path}/${video.videoId}.m4a'),
            File('${dir.path}/${video.videoId}.webm'),
            File('${dir.path}/${video.videoId}.mp3'),
          ];
          final file = candidates.firstWhere(
            (f) => f.existsSync(),
            orElse: () => File('${dir.path}/${video.videoId}.m4a'),
          );
          final received = await file.exists() ? await file.length() : 0;

          final extracted = await _downloadExtractor.getBestAudio(
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
