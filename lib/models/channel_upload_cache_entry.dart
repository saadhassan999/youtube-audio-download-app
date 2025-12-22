class ChannelUploadCacheEntry {
  ChannelUploadCacheEntry({
    required this.channelId,
    required this.videoId,
    required this.title,
    required this.thumbnailUrl,
    required this.cachedAt,
    this.publishedAt,
  });

  final String channelId;
  final String videoId;
  final String title;
  final String thumbnailUrl;
  final DateTime cachedAt;
  final DateTime? publishedAt;

  Map<String, dynamic> toMap() => {
        'channelId': channelId,
        'videoId': videoId,
        'title': title,
        'thumbnailUrl': thumbnailUrl,
        'cachedAt': cachedAt.millisecondsSinceEpoch,
        'publishedAt': publishedAt?.millisecondsSinceEpoch,
      };

  factory ChannelUploadCacheEntry.fromMap(Map<String, dynamic> map) {
    final publishedMs = map['publishedAt'] as int?;
    final cachedMs = map['cachedAt'] as int?;
    return ChannelUploadCacheEntry(
      channelId: map['channelId'] as String,
      videoId: map['videoId'] as String,
      title: map['title'] as String? ?? '',
      thumbnailUrl: map['thumbnailUrl'] as String? ?? '',
      cachedAt: cachedMs != null
          ? DateTime.fromMillisecondsSinceEpoch(cachedMs, isUtc: true)
          : DateTime.now().toUtc(),
      publishedAt: publishedMs != null
          ? DateTime.fromMillisecondsSinceEpoch(publishedMs, isUtc: true)
          : null,
    );
  }
}

class ChannelCacheMeta {
  ChannelCacheMeta({
    required this.channelId,
    required this.lastFetchedAt,
  });

  final String channelId;
  final DateTime lastFetchedAt;
}
