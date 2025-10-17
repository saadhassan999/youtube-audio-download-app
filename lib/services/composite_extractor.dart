import 'extractor_service.dart';

class CompositeExtractor implements ExtractorService {
  final ExtractorService primary;
  final ExtractorService fallback;

  const CompositeExtractor(this.primary, this.fallback);

  @override
  Future<ExtractedAudio> getBestAudio(String videoId) async {
    try {
      return await primary.getBestAudio(videoId);
    } catch (_) {
      return await fallback.getBestAudio(videoId);
    }
  }
}
