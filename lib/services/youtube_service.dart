import 'dart:collection';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

import '../config/app_config.dart';
import '../models/channel.dart';
import '../models/video.dart';
import '../utils/rss_parser.dart';

class YouTubeService {
  static const _maxCacheEntries = 20;
  static final LinkedHashMap<String, List<Channel>> _suggestionCache =
      LinkedHashMap();
  static DateTime? _rateLimitPauseUntil;
  static http.Client? _activeSearchClient;

  static String get _apiKey => AppConfig.youtubeApiKey;
  static bool get _hasApiKey => _apiKey.isNotEmpty;

  /// YouTube channel RSS feed fetch used for syncing videos.
  @pragma('vm:entry-point')
  static Future<List<Video>> fetchChannelVideos(String channelId) async {
    final url =
        'https://www.youtube.com/feeds/videos.xml?channel_id=$channelId';
    final response = await http.get(Uri.parse(url));
    if (response.statusCode == 200) {
      return parseRssFeed(response.body);
    } else {
      throw Exception('Failed to load RSS feed');
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

    final channelIds = <String>[];
    for (final item in items) {
      final channelId = item['id']?['channelId'] as String?;
      if (channelId != null) {
        channelIds.add(channelId);
      }
    }

    if (channelIds.isEmpty) {
      return [];
    }

    final details = await _fetchChannelDetails(client, channelIds);
    return channelIds
        .map((id) => details[id])
        .whereType<Channel>()
        .toList(growable: false);
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

      final hidden =
          statistics['hiddenSubscriberCount']?.toString().toLowerCase() ==
          'true';
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
              // youtube_explode does not expose subscriber counts
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
          channels.add(Channel(id: channelId, name: channelName));
        }
      }

      return channels;
    } catch (e) {
      print('Error searching channels via web scraping: $e');
      return [];
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
}

class ChannelSearchException implements Exception {
  ChannelSearchException(this.message, {this.cause});

  final String message;
  final Object? cause;

  bool get isCancellation => cause is http.ClientException;

  @override
  String toString() => 'ChannelSearchException: $message';
}

class RateLimitException extends ChannelSearchException {
  RateLimitException(Duration? retryAfter)
    : retryAfter = retryAfter,
      super('YouTube rate limit exceeded.');

  final Duration? retryAfter;
}
