import 'package:flutter/services.dart';

import 'extractor_service.dart';

class NativeYtDlpExtractor implements ExtractorService {
  static const MethodChannel _channel = MethodChannel('yt_dlp_bridge');

  @override
  Future<ExtractedAudio> getBestAudio(String videoIdOrUrl) async {
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'extractBestAudio',
      {
        'videoIdOrUrl': videoIdOrUrl,
      },
    );

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
