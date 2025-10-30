import 'dart:async';
import 'dart:convert';

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

    final response = await _sendWithRetry(() => http.get(uri));
    if (response.statusCode != 200) {
      throw Exception(
        'YouTube API error ${response.statusCode}: '
        '${_shortenBody(response.body)}',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final items = data['items'] as List<dynamic>? ?? const [];
    if (items.isEmpty) return null;

    final first = items.first as Map<String, dynamic>;
    final contentDetails =
        first['contentDetails'] as Map<String, dynamic>? ?? const {};
    final related =
        contentDetails['relatedPlaylists'] as Map<String, dynamic>? ?? const {};
    final uploads = related['uploads'];
    return uploads is String ? uploads : null;
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

    final response = await _sendWithRetry(() => http.get(uri));
    if (response.statusCode != 200) {
      throw Exception(
        'YouTube API error ${response.statusCode}: '
        '${_shortenBody(response.body)}',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final items = data['items'] as List<dynamic>? ?? const [];

    final videos = <VideoItem>[];
    for (final rawItem in items) {
      if (rawItem is! Map<String, dynamic>) continue;
      final snippet =
          rawItem['snippet'] as Map<String, dynamic>? ?? const <String, dynamic>{};
      final contentDetails =
          rawItem['contentDetails'] as Map<String, dynamic>? ?? const <String, dynamic>{};

      final videoId = contentDetails['videoId'] as String? ?? snippet['resourceId']?['videoId'] as String?;
      if (videoId == null || videoId.isEmpty) {
        continue; // skip unavailable/private entries
      }

      final publishedIso = (contentDetails['videoPublishedAt'] as String?) ??
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
  }

  Future<http.Response> _sendWithRetry(
    Future<http.Response> Function() request,
  ) async {
    const maxAttempts = 3;
    const delays = [200, 600, 1200];

    http.Response? lastResponse;
    Object? lastError;

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
      } on Exception catch (e) {
        lastError = e;
        if (attempt < maxAttempts - 1) {
          await Future<void>.delayed(Duration(milliseconds: delays[attempt]));
        }
      }
    }

    if (lastResponse != null) {
      throw Exception(
        'YouTube API error ${lastResponse.statusCode}: '
        '${_shortenBody(lastResponse.body)}',
      );
    }
    throw Exception('YouTube API request failed: $lastError');
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
