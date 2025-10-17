class ExtractedAudio {
  final String url;
  final String mimeType;
  final int? bitrateKbps;
  final String? container;

  const ExtractedAudio({
    required this.url,
    required this.mimeType,
    this.bitrateKbps,
    this.container,
  });
}

abstract class ExtractorService {
  Future<ExtractedAudio> getBestAudio(String videoId);
}
