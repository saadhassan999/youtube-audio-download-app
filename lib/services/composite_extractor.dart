import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import 'extractor_service.dart';
import 'youtube_explode_extractor.dart';

class CompositeExtractor implements ExtractorService {
  final ExtractorService primary;
  final ExtractorService fallback;
  final Duration? primaryTimeout;
  final bool runFallbackInIsolate;

  const CompositeExtractor(
    this.primary,
    this.fallback, {
    // Set to null to disable timeout, or provide a Duration to enforce one.
    this.primaryTimeout = const Duration(seconds: 60),
    this.runFallbackInIsolate = false,
  });

  @override
  Future<ExtractedAudio> getBestAudio(String videoId) async {
    final sw = Stopwatch()..start();
    try {
      final Future<ExtractedAudio> primaryFuture =
          primary.getBestAudio(videoId);
      final ExtractedAudio result = primaryTimeout == null
          ? await primaryFuture
          : await primaryFuture.timeout(
              primaryTimeout!,
              onTimeout: () =>
                  throw TimeoutException('Primary extractor timed out'),
            );
      debugPrint(
        '[CompositeExtractor] primary succeeded in ${sw.elapsedMilliseconds}ms',
      );
      return result;
    } catch (e) {
      debugPrint(
        '[CompositeExtractor] primary failed after ${sw.elapsedMilliseconds}ms: $e; falling back',
      );
      final fbSw = Stopwatch()..start();
      final result = runFallbackInIsolate && fallback is YoutubeExplodeExtractor
          ? await Isolate.run<ExtractedAudio>(
              () => YoutubeExplodeExtractor().getBestAudio(videoId),
            )
          : await fallback.getBestAudio(videoId);
      debugPrint(
        '[CompositeExtractor] fallback succeeded in ${fbSw.elapsedMilliseconds}ms',
      );
      return result;
    }
  }
}
