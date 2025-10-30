import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

import '../config/app_config.dart';
import '../core/fetch_exception.dart';
import '../models/channel.dart';
import '../models/video.dart';
import '../utils/rss_parser.dart';
import '../utils/youtube_utils.dart';

class YouTubeService {
  static const _maxCacheEntries = 20;
  static final LinkedHashMap<String, List<Channel>> _suggestionCache =
      LinkedHashMap();
  static final LinkedHashMap<String, List<Video>> _videoSuggestionCache =
      LinkedHashMap();
  static DateTime? _rateLimitPauseUntil;
  static http.Client? _activeSearchClient;

  static String get _apiKey => AppConfig.youtubeApiKey;
  static bool get _hasApiKey => _apiKey.isNotEmpty;

  /// YouTube channel RSS feed fetch used for syncing videos.
  @pragma('vm:entry-point')
  static Future<List<Video>> fetchChannelVideos(
    String channelId, {
    bool forceRefresh = false,
  }) async {
    final queryParams = <String, String>{'channel_id': channelId};
    if (forceRefresh) {
      queryParams['ts'] = DateTime.now().millisecondsSinceEpoch.toString();
    }

    final uri = Uri.https('www.youtube.com', '/feeds/videos.xml', queryParams);

    final headers = <String, String>{};
    if (forceRefresh) {
      headers['Cache-Control'] = 'no-cache';
      headers['Pragma'] = 'no-cache';
    }

    try {
      final response = await http.get(
        uri,
        headers: headers.isEmpty ? null : headers,
      );
      if (response.statusCode == 200) {
        return parseRssFeed(response.body);
      }
      throw FetchException(
        message: 'Failed to load RSS feed (HTTP ${response.statusCode})',
      );
    } on SocketException catch (e) {
      throw FetchException(
        message: 'No internet connection',
        isOffline: true,
        cause: e,
      );
    } on http.ClientException catch (e) {
      throw FetchException(
        message: 'Unable to reach YouTube right now.',
        isOffline: true,
        cause: e,
      );
    } catch (e) {
      if (e is FetchException) rethrow;
      throw FetchException(message: 'Failed to load RSS feed', cause: e);
    }
  }

  static void cancelActiveSearch() {
    _activeSearchClient?.close();
    _activeSearchClient = null;
  }

  /// Search for YouTube channels by name, returning suggestions enriched with
  /// thumbnails, handles, and subscriber counts when available.
  static Future<List<Channel>> getChannelSuggestions(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return [];
    }

    final normalizedKey = trimmed.toLowerCase();
    final cached = _suggestionCache[normalizedKey];
    if (cached != null) {
      // Refresh LRU order.
      _suggestionCache.remove(normalizedKey);
      _suggestionCache[normalizedKey] = cached;
      return cached;
    }

    _ensureNotRateLimited();

    final client = http.Client();
    _setActiveSearchClient(client);

    try {
      List<Channel> results = [];

      if (_hasApiKey) {
        results = await _searchChannelsWithApi(client, trimmed);
      }

      if (results.isEmpty) {
        results = await _searchChannelsWithYoutubeExplode(trimmed);
      }

      if (results.isEmpty) {
        results = await _searchChannelsWebScraping(trimmed, client);
      }

      _writeCache(normalizedKey, results);
      return results;
    } on RateLimitException {
      rethrow;
    } catch (e) {
      throw ChannelSearchException(
        'Unable to reach YouTube right now. Please try again.',
        cause: e,
      );
    } finally {
      _clearActiveClient(client);
    }
  }

  static Future<List<Video>> getVideoSuggestions(
    String query, {
    int maxResults = 10,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return [];
    }

    final cacheKey = '${trimmed.toLowerCase()}::$maxResults';

    final directId = tryParseVideoId(trimmed);
    if (directId != null) {
      final video = await getVideoById(directId);
      if (video != null) {
        _writeVideoCache(cacheKey, [video]);
        return [video];
      }
    }
    final cached = _videoSuggestionCache[cacheKey];
    if (cached != null) {
      _videoSuggestionCache.remove(cacheKey);
      _videoSuggestionCache[cacheKey] = cached;
      return cached;
    }

    _ensureNotRateLimited();

    List<Video> results = [];

    if (_hasApiKey) {
      final client = http.Client();
      _setActiveSearchClient(client);
      try {
        results = await _searchVideosWithApi(
          client,
          trimmed,
          maxResults: maxResults,
        );
      } on RateLimitException {
        rethrow;
      } on ChannelSearchException catch (e) {
        throw VideoSearchException(e.message, cause: e.cause);
      } catch (e) {
        throw VideoSearchException(
          'Unable to reach YouTube right now. Please try again.',
          cause: e,
        );
      } finally {
        _clearActiveClient(client);
      }
    }

    if (results.isEmpty) {
      results = await _searchVideosWithYoutubeExplode(
        trimmed,
        maxResults: maxResults,
      );
    }

    _writeVideoCache(cacheKey, results);
    return results;
  }

  static Future<Video?> getVideoById(String videoId) async {
    final trimmed = videoId.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    _ensureNotRateLimited();

    if (_hasApiKey) {
      final client = http.Client();
      try {
        final details = await _fetchVideoDetails(client, [trimmed]);
        return details[trimmed];
      } on RateLimitException {
        rethrow;
      } on ChannelSearchException catch (e) {
        throw VideoSearchException(e.message, cause: e.cause);
      } catch (_) {
        // Fall through to youtube_explode fallback.
      } finally {
        client.close();
      }
    }

    try {
      final ytExplode = yt.YoutubeExplode();
      try {
        final meta = await ytExplode.videos.get(trimmed);
        final published =
            meta.publishDate?.toUtc() ??
            meta.uploadDate?.toUtc() ??
            DateTime.now().toUtc();
        return Video(
          id: meta.id.value,
          title: meta.title,
          published: published.toUtc(),
          thumbnailUrl: meta.thumbnails.highResUrl,
          channelName: meta.author,
          channelId: meta.channelId.value,
          duration: meta.duration,
        );
      } finally {
        ytExplode.close();
      }
    } catch (_) {
      return null;
    }
  }

  static Future<List<Channel>> _searchChannelsWithApi(
    http.Client client,
    String query,
  ) async {
    final searchUrl = Uri.https('www.googleapis.com', '/youtube/v3/search', {
      'part': 'snippet',
      'q': query,
      'type': 'channel',
      'maxResults': '12',
      'key': _apiKey,
    });

    final searchResponse = await client.get(searchUrl);
    if (searchResponse.statusCode != 200) {
      _handleApiError(searchResponse);
    }

    final searchData = json.decode(searchResponse.body) as Map<String, dynamic>;
    final items = (searchData['items'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();

    if (items.isEmpty) {
      return [];
    }

    final channelIds = items
        .map((item) => item['id']?['channelId'] as String?)
        .whereType<String>()
        .toList(growable: false);
    if (channelIds.isEmpty) {
      return [];
    }

    final details = await _fetchChannelDetails(client, channelIds);

    final results = <Channel>[];
    for (final item in items) {
      final channelId = item['id']?['channelId'] as String?;
      if (channelId == null) continue;

      final detail = details[channelId];
      if (detail != null) {
        results.add(detail);
        continue;
      }

      final snippet = item['snippet'] as Map<String, dynamic>? ?? {};
      final thumbnails =
          snippet['thumbnails'] as Map<String, dynamic>? ?? const {};
      results.add(
        Channel(
          id: channelId,
          name: snippet['title'] as String? ?? '',
          description: snippet['description'] as String? ?? '',
          thumbnailUrl: _selectThumbnailUrl(thumbnails),
        ),
      );
    }

    return results;
  }

  static Future<Map<String, Channel>> _fetchChannelDetails(
    http.Client client,
    List<String> ids,
  ) async {
    final detailsUrl = Uri.https('www.googleapis.com', '/youtube/v3/channels', {
      'part': 'snippet,statistics',
      'id': ids.join(','),
      'maxResults': ids.length.toString(),
      'key': _apiKey,
    });

    final detailResponse = await client.get(detailsUrl);
    if (detailResponse.statusCode != 200) {
      _handleApiError(detailResponse);
    }

    final detailData = json.decode(detailResponse.body) as Map<String, dynamic>;
    final items = (detailData['items'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
    final result = <String, Channel>{};

    for (final item in items) {
      final id = item['id'] as String?;
      if (id == null) continue;

      final snippet = item['snippet'] as Map<String, dynamic>? ?? {};
      final statistics =
          item['statistics'] as Map<String, dynamic>? ?? const {};

      final thumbnails =
          snippet['thumbnails'] as Map<String, dynamic>? ?? const {};
      final thumbnailUrl = _selectThumbnailUrl(thumbnails);

      final customUrl = snippet['customUrl'] as String?;
      final handle = (customUrl != null && customUrl.isNotEmpty)
          ? _formatHandle(customUrl)
          : null;

      final hidden = statistics['hiddenSubscriberCount'] == true;
      final subscriberCount = hidden
          ? null
          : int.tryParse(statistics['subscriberCount']?.toString() ?? '');

      result[id] = Channel(
        id: id,
        name: snippet['title'] as String? ?? '',
        description: snippet['description'] as String? ?? '',
        thumbnailUrl: thumbnailUrl,
        handle: handle,
        subscriberCount: subscriberCount,
        hiddenSubscriberCount: hidden,
      );
    }

    return result;
  }

  static Future<List<Channel>> _searchChannelsWithYoutubeExplode(
    String query,
  ) async {
    final ytExplode = yt.YoutubeExplode();
    try {
      final searchList = await ytExplode.search.searchContent(
        query,
        filter: yt.TypeFilters.channel,
      );

      return searchList
          .whereType<yt.SearchChannel>()
          .take(12)
          .map(
            (channel) => Channel(
              id: channel.id.value,
              name: channel.name,
              description: channel.description,
              thumbnailUrl: channel.thumbnails.isNotEmpty
                  ? channel.thumbnails.last.url.toString()
                  : '',
              handle: null,
              subscriberCount: null,
              hiddenSubscriberCount: false,
            ),
          )
          .toList();
    } catch (e) {
      print('YouTubeExplode channel search error: $e');
      return [];
    } finally {
      ytExplode.close();
    }
  }

  static Future<List<Channel>> _searchChannelsWebScraping(
    String query,
    http.Client client,
  ) async {
    try {
      final searchUrl =
          'https://www.youtube.com/results?search_query=${Uri.encodeComponent(query)}&sp=EgIQAg%3D%3D';

      final response = await client.get(
        Uri.parse(searchUrl),
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        },
      );

      if (response.statusCode != 200) {
        return [];
      }

      final html = response.body;
      final channels = <Channel>[];

      final channelPattern = RegExp(
        r'"channelId":"(UC[\w-]{21,})".*?"title":"([^"]+)"',
        dotAll: true,
      );
      final matches = channelPattern.allMatches(html);

      for (final match in matches.take(12)) {
        final channelId = match.group(1);
        final channelName = match.group(2);

        if (channelId != null && channelName != null) {
          channels.add(
            Channel(
              id: channelId,
              name: channelName,
              subscriberCount: null,
              hiddenSubscriberCount: false,
            ),
          );
        }
      }

      return channels;
    } catch (e) {
      print('Error searching channels via web scraping: $e');
      return [];
    }
  }

  static Future<List<Video>> _searchVideosWithApi(
    http.Client client,
    String query, {
    int maxResults = 10,
  }) async {
    final searchUrl = Uri.https('www.googleapis.com', '/youtube/v3/search', {
      'part': 'snippet',
      'q': query,
      'type': 'video',
      'maxResults': maxResults.toString(),
      'key': _apiKey,
      'fields': 'items(id/videoId)',
    });

    final searchResponse = await client.get(searchUrl);
    if (searchResponse.statusCode != 200) {
      try {
        _handleApiError(searchResponse);
      } on RateLimitException {
        rethrow;
      } on ChannelSearchException catch (e) {
        throw VideoSearchException(e.message, cause: e.cause);
      }
    }

    final searchData = json.decode(searchResponse.body) as Map<String, dynamic>;
    final items = (searchData['items'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
    if (items.isEmpty) {
      return [];
    }

    final ids = <String>[];
    for (final item in items) {
      final id = item['id'] as Map<String, dynamic>?;
      final videoId = id?['videoId'] as String?;
      if (videoId != null) {
        ids.add(videoId);
      }
    }

    if (ids.isEmpty) {
      return [];
    }

    final detailMap = await _fetchVideoDetails(client, ids);
    final videos = <Video>[];
    for (final id in ids) {
      final video = detailMap[id];
      if (video != null) {
        videos.add(video);
      }
    }
    return videos;
  }

  static Future<Map<String, Video>> _fetchVideoDetails(
    http.Client client,
    List<String> ids,
  ) async {
    if (ids.isEmpty) {
      return {};
    }

    final detailsUrl = Uri.https('www.googleapis.com', '/youtube/v3/videos', {
      'part': 'snippet,contentDetails',
      'id': ids.join(','),
      'maxResults': ids.length.toString(),
      'key': _apiKey,
      'fields':
          'items(id,snippet(title,channelTitle,channelId,publishedAt,thumbnails),contentDetails(duration))',
    });

    final response = await client.get(detailsUrl);
    if (response.statusCode != 200) {
      try {
        _handleApiError(response);
      } on RateLimitException {
        rethrow;
      } on ChannelSearchException catch (e) {
        throw VideoSearchException(e.message, cause: e.cause);
      }
    }

    final data = json.decode(response.body) as Map<String, dynamic>;
    final items = (data['items'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
    final result = <String, Video>{};

    for (final item in items) {
      final id = item['id'] as String?;
      if (id == null) {
        continue;
      }
      final snippet = item['snippet'] as Map<String, dynamic>? ?? const {};
      final content =
          item['contentDetails'] as Map<String, dynamic>? ?? const {};

      final thumbnails =
          snippet['thumbnails'] as Map<String, dynamic>? ?? const {};
      final rawPublished = snippet['publishedAt'] as String?;
      DateTime published;
      if (rawPublished != null) {
        try {
          published = DateTime.parse(rawPublished).toUtc();
        } catch (_) {
          published = DateTime.now().toUtc();
        }
      } else {
        published = DateTime.now().toUtc();
      }

      final rawDuration = content['duration'] as String? ?? '';
      final duration = _parseIso8601Duration(rawDuration);

      result[id] = Video(
        id: id,
        title: snippet['title'] as String? ?? '',
        published: published,
        thumbnailUrl: _selectThumbnailUrl(thumbnails),
        channelName: snippet['channelTitle'] as String? ?? '',
        channelId: snippet['channelId'] as String? ?? '',
        duration: duration,
      );
    }

    return result;
  }

  static Future<List<Video>> _searchVideosWithYoutubeExplode(
    String query, {
    int maxResults = 10,
  }) async {
    final ytExplode = yt.YoutubeExplode();
    try {
      final searchList = await ytExplode.search.searchContent(
        query,
        filter: yt.TypeFilters.video,
      );

      final results = <Video>[];
      for (final item in searchList.whereType<yt.SearchVideo>()) {
        final duration = _parseColonDuration(item.duration);
        final thumbnail = item.thumbnails.isNotEmpty
            ? item.thumbnails.first.url.toString()
            : '';
        results.add(
          Video(
            id: item.id.value,
            title: item.title,
            published: DateTime.now().toUtc(),
            thumbnailUrl: thumbnail,
            channelName: item.author,
            channelId: item.channelId,
            duration: duration,
          ),
        );
        if (results.length >= maxResults) {
          break;
        }
      }
      return results;
    } catch (e) {
      print('YouTubeExplode video search error: $e');
      return [];
    } finally {
      ytExplode.close();
    }
  }

  static void _handleApiError(http.Response response) {
    final status = response.statusCode;
    try {
      final body = json.decode(response.body) as Map<String, dynamic>;
      final error = body['error'] as Map<String, dynamic>?;
      final errors = (error?['errors'] as List<dynamic>?)
          ?.cast<Map<String, dynamic>>();
      final reason =
          errors?.firstWhere(
                (element) => element['reason'] != null,
                orElse: () => const {},
              )['reason']
              as String?;

      if (_isRateLimitStatus(status, reason)) {
        final backoff = const Duration(seconds: 30);
        _rateLimitPauseUntil = DateTime.now().add(backoff);
        throw RateLimitException(backoff);
      }

      final message = error?['message'] as String?;
      throw ChannelSearchException(
        message ?? 'YouTube API error (HTTP $status)',
      );
    } catch (e) {
      if (e is ChannelSearchException || e is RateLimitException) {
        rethrow;
      }

      if (_isRateLimitStatus(status, null)) {
        final backoff = const Duration(seconds: 30);
        _rateLimitPauseUntil = DateTime.now().add(backoff);
        throw RateLimitException(backoff);
      }

      throw ChannelSearchException(
        'YouTube API error (HTTP $status)',
        cause: e,
      );
    }
  }

  static bool _isRateLimitStatus(int status, String? reason) =>
      status == 429 ||
      status == 403 &&
          (reason == 'quotaExceeded' || reason == 'rateLimitExceeded');

  static void _setActiveSearchClient(http.Client client) {
    cancelActiveSearch();
    _activeSearchClient = client;
  }

  static void _clearActiveClient(http.Client client) {
    if (_activeSearchClient == client) {
      _activeSearchClient = null;
    }
    client.close();
  }

  static void _writeCache(String key, List<Channel> value) {
    _suggestionCache.remove(key);
    _suggestionCache[key] = value;
    if (_suggestionCache.length > _maxCacheEntries) {
      _suggestionCache.remove(_suggestionCache.keys.first);
    }
  }

  static void _writeVideoCache(String key, List<Video> value) {
    _videoSuggestionCache.remove(key);
    _videoSuggestionCache[key] = value;
    if (_videoSuggestionCache.length > _maxCacheEntries) {
      _videoSuggestionCache.remove(_videoSuggestionCache.keys.first);
    }
  }

  static void _ensureNotRateLimited() {
    if (_rateLimitPauseUntil == null) {
      return;
    }
    final remaining = _rateLimitPauseUntil!.difference(DateTime.now());
    if (remaining.isNegative) {
      _rateLimitPauseUntil = null;
      return;
    }
    throw RateLimitException(remaining);
  }

  static String _selectThumbnailUrl(Map<String, dynamic> thumbnails) {
    final candidates = [
      thumbnails['high'],
      thumbnails['medium'],
      thumbnails['default'],
    ];
    for (final candidate in candidates) {
      final url = candidate?['url'] as String?;
      if (url != null && url.isNotEmpty) {
        return url;
      }
    }
    return '';
  }

  static String _formatHandle(String raw) {
    final handle = raw.trim();
    if (handle.isEmpty) return '';
    return handle.startsWith('@') ? handle : '@$handle';
  }

  static Duration? _parseIso8601Duration(String input) {
    if (input.isEmpty) return null;
    final exp = RegExp(
      r'^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$',
    );
    final match = exp.firstMatch(input);
    if (match == null) {
      return null;
    }
    final days = int.tryParse(match.group(1) ?? '');
    final hours = int.tryParse(match.group(2) ?? '');
    final minutes = int.tryParse(match.group(3) ?? '');
    final seconds = int.tryParse(match.group(4) ?? '');
    final totalSeconds =
        (days ?? 0) * 86400 +
        (hours ?? 0) * 3600 +
        (minutes ?? 0) * 60 +
        (seconds ?? 0);
    if (totalSeconds == 0) {
      return Duration.zero;
    }
    return Duration(seconds: totalSeconds);
  }

  static Duration? _parseColonDuration(String? input) {
    if (input == null || input.isEmpty) {
      return null;
    }
    if (input.toLowerCase() == 'live') {
      return null;
    }
    final parts = input.split(':').map(int.tryParse).toList();
    if (parts.any((element) => element == null)) {
      return null;
    }
    while (parts.length < 3) {
      parts.insert(0, 0);
    }
    final hours = parts[parts.length - 3] ?? 0;
    final minutes = parts[parts.length - 2] ?? 0;
    final seconds = parts[parts.length - 1] ?? 0;
    return Duration(hours: hours, minutes: minutes, seconds: seconds);
  }
}

class ChannelSearchException implements Exception {
  ChannelSearchException(this.message, {this.cause});

  final String message;
  final Object? cause;

  bool get isCancellation => cause is http.ClientException;

  @override
  String toString() => 'ChannelSearchException: $message';
}

class VideoSearchException extends ChannelSearchException {
  VideoSearchException(String message, {Object? cause})
    : super(message, cause: cause);
}

class RateLimitException extends ChannelSearchException {
  RateLimitException(Duration? retryAfter)
    : retryAfter = retryAfter,
      super('YouTube rate limit exceeded.');

  final Duration? retryAfter;
}
