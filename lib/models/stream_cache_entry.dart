class StreamCacheEntry {
  final String videoId;
  final String? lastStreamUrl;
  final DateTime? lastStreamUrlUpdatedAt;
  final String source;

  const StreamCacheEntry({
    required this.videoId,
    required this.lastStreamUrl,
    required this.lastStreamUrlUpdatedAt,
    this.source = 'unknown',
  });
}
