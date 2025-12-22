import '../models/channel_upload_cache_entry.dart';
import '../services/database_service.dart';
import '../services/youtube_service.dart';
import '../utils/constants.dart';

class ChannelUploadsCacheRepository {
  ChannelUploadsCacheRepository._();

  static final ChannelUploadsCacheRepository instance =
      ChannelUploadsCacheRepository._();

  final DatabaseService _db = DatabaseService.instance;

  Duration get _ttl => Duration(minutes: kChannelUploadsCacheTtlMinutes);

  bool isStale(DateTime? lastFetchedAt) {
    if (lastFetchedAt == null) return true;
    return DateTime.now().toUtc().difference(lastFetchedAt) > _ttl;
  }

  Future<List<ChannelUploadCacheEntry>> getCachedUploads(
    String channelId,
  ) {
    return _db.getChannelUploadsCache(channelId);
  }

  Future<ChannelCacheMeta?> getCacheMeta(String channelId) {
    return _db.getChannelCacheMeta(channelId);
  }

  Future<List<ChannelUploadCacheEntry>> refreshFromRss(
    String channelId, {
    bool forceRefresh = false,
  }) async {
    final videos = await YouTubeService.fetchChannelVideos(
      channelId,
      forceRefresh: forceRefresh,
    );
    final now = DateTime.now().toUtc();
    final entries = videos.map((video) {
      final thumb = (video.thumbnailUrl.isNotEmpty)
          ? video.thumbnailUrl
          : _fallbackThumbnail(video.id);
      return ChannelUploadCacheEntry(
        channelId: channelId,
        videoId: video.id,
        title: video.title,
        publishedAt: video.published.toUtc(),
        thumbnailUrl: thumb,
        cachedAt: now,
      );
    }).toList(growable: false);

    await _db.saveChannelUploadsCache(channelId, entries, now);
    return entries;
  }

  String _fallbackThumbnail(String videoId) =>
      'https://i.ytimg.com/vi/$videoId/hqdefault.jpg';
}
