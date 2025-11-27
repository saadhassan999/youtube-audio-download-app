import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'extractor_service.dart';

class NativeYtDlpExtractor implements ExtractorService {
  static const MethodChannel _channel = MethodChannel('yt_dlp_bridge');

  /// When true, use the download-specific native method; otherwise, stream.
  final bool forDownload;

  const NativeYtDlpExtractor({this.forDownload = false});

  @override
  Future<ExtractedAudio> getBestAudio(String videoIdOrUrl) async {
    final sw = Stopwatch()..start();
    final method =
        forDownload ? 'extractBestAudioDownload' : 'extractBestAudioStream';
    debugPrint(
      '[NativeYtDlpExtractor] calling $method for $videoIdOrUrl (pre-channel)',
    );
    try {
      final result = await _invokeExtract(videoIdOrUrl, method);
      debugPrint(
        '[NativeYtDlpExtractor] success for $videoIdOrUrl in ${sw.elapsedMilliseconds}ms',
      );
      return result;
    } on PlatformException catch (e) {
      final msg = (e.message ?? '').toLowerCase();
      final needsReinit =
          e.code == 'EXTRACT_FAIL' && msg.contains('not initialized');

      if (needsReinit) {
        debugPrint(
          '[NativeYtDlpExtractor] EXTRACT_FAIL not initialized; reinitializing then retrying for $videoIdOrUrl',
        );
        try {
          await _channel.invokeMethod('reinitializeYtDlp');
        } catch (reinitError) {
          debugPrint(
            '[NativeYtDlpExtractor] reinitializeYtDlp failed: $reinitError',
          );
          rethrow;
        }
        final retrySw = Stopwatch()..start();
        final retryResult = await _invokeExtract(videoIdOrUrl, method);
        debugPrint(
          '[NativeYtDlpExtractor] retry success for $videoIdOrUrl in ${retrySw.elapsedMilliseconds}ms',
        );
        return retryResult;
      }
      rethrow;
    }
  }

  Future<ExtractedAudio> _invokeExtract(
    String videoIdOrUrl,
    String method,
  ) async {
    debugPrint('[NativeYtDlpExtractor] invoking native $method on UI isolate');
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      method,
      {
        'videoIdOrUrl': videoIdOrUrl,
      },
    );
    debugPrint('[NativeYtDlpExtractor] native $method returned to Dart');

    if (result == null || result['url'] == null) {
      throw Exception('Native extractor failed to return URL');
    }

    return ExtractedAudio(
      url: result['url'] as String,
      mimeType: (result['mimeType'] as String?) ?? 'audio/mp4',
      container: result['container'] as String?,
      bitrateKbps: (result['bitrateKbps'] as num?)?.toInt(),
    );
  }
}
