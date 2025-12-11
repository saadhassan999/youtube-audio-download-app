import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

class YoutubeApiService {
  YoutubeApiService(this.apiKey);

  final String apiKey;

  Future<String?> getUploadsPlaylistId(String channelId) async {
    final uri = Uri.https('www.googleapis.com', '/youtube/v3/channels', {
      'part': 'contentDetails',
      'id': channelId,
      'key': apiKey,
    });

    try {
      final response = await _sendWithRetry(() => http.get(uri));
      _throwForBadStatus(response, context: 'channel details');

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final items = data['items'] as List<dynamic>? ?? const [];
      if (items.isEmpty) return null;

      final first = items.first as Map<String, dynamic>;
      final contentDetails =
          first['contentDetails'] as Map<String, dynamic>? ?? const {};
      final related =
          contentDetails['relatedPlaylists'] as Map<String, dynamic>? ??
          const {};
      final uploads = related['uploads'];
      return uploads is String ? uploads : null;
    } on ChannelRefreshException {
      rethrow;
    } catch (e, stack) {
      throw ChannelRefreshException(
        message: 'Unable to fetch channel details.',
        isOffline: ChannelRefreshException.isNetworkError(e),
        cause: e,
        stackTrace: stack,
      );
    }
  }

  Future<UploadsPage> fetchUploadsPage({
    required String uploadsPlaylistId,
    String? pageToken,
  }) async {
    final params = <String, String>{
      'part': 'snippet,contentDetails',
      'playlistId': uploadsPlaylistId,
      'maxResults': '50',
      'key': apiKey,
      if (pageToken != null) 'pageToken': pageToken,
    };

    final uri = Uri.https(
      'www.googleapis.com',
      '/youtube/v3/playlistItems',
      params,
    );

    try {
      final response = await _sendWithRetry(() => http.get(uri));
      _throwForBadStatus(response, context: 'playlist items');

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final items = data['items'] as List<dynamic>? ?? const [];

      final videos = <VideoItem>[];
      for (final rawItem in items) {
        if (rawItem is! Map<String, dynamic>) continue;
        final snippet =
            rawItem['snippet'] as Map<String, dynamic>? ??
            const <String, dynamic>{};
        final contentDetails =
            rawItem['contentDetails'] as Map<String, dynamic>? ??
            const <String, dynamic>{};

        final videoId =
            contentDetails['videoId'] as String? ??
            snippet['resourceId']?['videoId'] as String?;
        if (videoId == null || videoId.isEmpty) {
          continue; // skip unavailable/private entries
        }

        final publishedIso =
            (contentDetails['videoPublishedAt'] as String?) ??
            (snippet['publishedAt'] as String?);
        final publishedAt =
            DateTime.tryParse(publishedIso ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0);

        videos.add(
          VideoItem(
            videoId: videoId,
            title: (snippet['title'] as String?) ?? '',
            description: (snippet['description'] as String?) ?? '',
            publishedAt: publishedAt,
            thumbnailUrl: _pickBestThumbnail(
              snippet['thumbnails'] as Map<String, dynamic>?,
            ),
            channelId: (snippet['channelId'] as String?) ?? '',
          ),
        );
      }

      final pageInfo = data['pageInfo'] as Map<String, dynamic>? ?? const {};

      return UploadsPage(
        videos: videos,
        nextPageToken: data['nextPageToken'] as String?,
        totalResults: (pageInfo['totalResults'] as int?) ?? 0,
      );
    } on ChannelRefreshException {
      rethrow;
    } catch (e, stack) {
      throw ChannelRefreshException(
        message: 'Unable to fetch uploads.',
        isOffline: ChannelRefreshException.isNetworkError(e),
        cause: e,
        stackTrace: stack,
      );
    }
  }

  Future<http.Response> _sendWithRetry(
    Future<http.Response> Function() request,
  ) async {
    const maxAttempts = 3;
    const delays = [200, 600, 1200];

    http.Response? lastResponse;
    Object? lastError;
    StackTrace? lastStackTrace;

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        final response = await request();
        if (response.statusCode >= 500 && response.statusCode < 600) {
          lastResponse = response;
          if (attempt < maxAttempts - 1) {
            await Future<void>.delayed(Duration(milliseconds: delays[attempt]));
            continue;
          }
        }
        return response;
      } on Exception catch (e, stack) {
        lastError = e;
        lastStackTrace = stack;
        if (attempt < maxAttempts - 1) {
          await Future<void>.delayed(Duration(milliseconds: delays[attempt]));
        }
      }
    }

    if (lastResponse != null) {
      final message =
          'YouTube API error ${lastResponse.statusCode}: '
          '${_shortenBody(lastResponse.body)}';
      throw ChannelRefreshException(
        message: message,
        isOffline: false,
        cause: message,
        stackTrace: StackTrace.current,
      );
    }

    if (lastError != null) {
      final offline = ChannelRefreshException.isNetworkError(lastError);
      final fallbackMessage = offline
          ? 'No internet connection'
          : 'YouTube API request failed.';
      throw ChannelRefreshException(
        message: fallbackMessage,
        isOffline: offline,
        cause: lastError,
        stackTrace: lastStackTrace,
      );
    }

    throw ChannelRefreshException(
      message: 'YouTube API request failed for an unknown reason.',
      isOffline: false,
    );
  }

  String? _pickBestThumbnail(Map<String, dynamic>? thumbnails) {
    if (thumbnails == null || thumbnails.isEmpty) return null;
    const priority = ['maxres', 'standard', 'high', 'medium', 'default'];
    for (final key in priority) {
      final entry = thumbnails[key];
      if (entry is Map<String, dynamic>) {
        final url = entry['url'];
        if (url is String && url.isNotEmpty) {
          return url;
        }
      }
    }
    return null;
  }

  String _shortenBody(String body) {
    if (body.length <= 120) return body;
    return '${body.substring(0, 117)}...';
  }

  void _throwForBadStatus(http.Response response, {required String context}) {
    if (response.statusCode == 200) return;
    throw ChannelRefreshException(
      message:
          'YouTube API error ${response.statusCode} while loading $context.',
      isOffline: false,
      cause: 'HTTP ${response.statusCode}: ${_shortenBody(response.body)}',
      stackTrace: StackTrace.current,
    );
  }
}

class UploadsPage {
  UploadsPage({
    required this.videos,
    required this.nextPageToken,
    required this.totalResults,
  });

  final List<VideoItem> videos;
  final String? nextPageToken;
  final int totalResults;
}

class VideoItem {
  const VideoItem({
    required this.videoId,
    required this.title,
    required this.description,
    required this.publishedAt,
    required this.thumbnailUrl,
    required this.channelId,
  });

  final String videoId;
  final String title;
  final String description;
  final DateTime publishedAt;
  final String? thumbnailUrl;
  final String channelId;
}

class ChannelRefreshException implements Exception {
  ChannelRefreshException({
    required this.message,
    required this.isOffline,
    this.cause,
    this.stackTrace,
  });

  final String message;
  final bool isOffline;
  final Object? cause;
  final StackTrace? stackTrace;

  static bool isNetworkError(Object error) {
    if (error is SocketException) return true;
    if (error is http.ClientException) {
      final msg = error.message.toLowerCase();
      if (_matchesNetworkMessage(msg)) return true;
    }
    final message = error.toString().toLowerCase();
    return _matchesNetworkMessage(message);
  }

  static bool _matchesNetworkMessage(String message) {
    return message.contains('failed host lookup') ||
        message.contains('no address associated with hostname') ||
        message.contains('network is unreachable') ||
        message.contains('temporary failure in name resolution') ||
        message.contains('socketexception');
  }

  @override
  String toString() => 'ChannelRefreshException($message, offline=$isOffline)';
}
