import 'dart:async';

import '../core/fetch_exception.dart';
import '../models/video.dart';
import '../services/youtube_service.dart';

class ChannelFetchResult {
  ChannelFetchResult({
    required this.videos,
    required this.fromCache,
  });

  final List<Video> videos;
  final bool fromCache;
}

class ChannelRepository {
  ChannelRepository._();

  static final ChannelRepository instance = ChannelRepository._();

  final Map<String, _ChannelCacheEntry> _cache = {};
  final Map<String, Future<List<Video>>> _inFlight = {};

  bool hasCachedVideos(String channelId) =>
      _cache[channelId]?.videos.isNotEmpty ?? false;

  bool isStale(String channelId) => _cache[channelId]?.isStale ?? false;

  void markStale(String channelId) {
    final entry = _cache[channelId];
    if (entry == null) return;
    entry.isStale = true;
  }

  void clearStale(String channelId) {
    final entry = _cache[channelId];
    if (entry == null) return;
    entry.isStale = false;
  }

  List<Video> getCachedVideos(String channelId) {
    final entry = _cache[channelId];
    if (entry == null) return const [];
    return List.unmodifiable(entry.videos);
  }

  Future<ChannelFetchResult> fetchChannelVideos(
    String channelId, {
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh) {
      final cached = _cache[channelId];
      if (cached != null && !cached.isStale) {
        return ChannelFetchResult(
          videos: List.unmodifiable(cached.videos),
          fromCache: true,
        );
      }
    } else {
      clearStale(channelId);
    }

    final existingFetch = _inFlight[channelId];
    if (existingFetch != null) {
      final videos = await existingFetch;
      return ChannelFetchResult(
        videos: List.unmodifiable(videos),
        fromCache: false,
      );
    }

    final fetchFuture = _loadFromNetwork(channelId, forceRefresh: forceRefresh);
    _inFlight[channelId] = fetchFuture;

    try {
      final videos = await fetchFuture;
      _cache[channelId] = _ChannelCacheEntry(
        videos: videos,
        fetchedAt: DateTime.now(),
      );
      return ChannelFetchResult(
        videos: List.unmodifiable(videos),
        fromCache: false,
      );
    } on FetchException catch (e) {
      if (e.isOffline) {
        markStale(channelId);
      }
      rethrow;
    } finally {
      _inFlight.remove(channelId);
    }
  }

  Future<List<Video>> _loadFromNetwork(
    String channelId, {
    required bool forceRefresh,
  }) async {
    final videos = await YouTubeService.fetchChannelVideos(
      channelId,
      forceRefresh: forceRefresh,
    );
    return List.unmodifiable(videos);
  }
}

class _ChannelCacheEntry {
  _ChannelCacheEntry({
    required this.videos,
    required this.fetchedAt,
  }) : isStale = false;

  final List<Video> videos;
  final DateTime fetchedAt;
  bool isStale;
}
