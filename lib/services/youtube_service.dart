import 'package:http/http.dart' as http;
import '../models/video.dart';
import '../models/channel.dart';
import '../utils/rss_parser.dart';
import 'dart:convert';

class YouTubeService {
  // YouTube Data API key - you'll need to get one from Google Cloud Console
  static const String _apiKey = 'YOUR_YOUTUBE_API_KEY'; // Replace with your actual API key
  
  @pragma('vm:entry-point')
  static Future<List<Video>> fetchChannelVideos(String channelId) async {
    final url = 'https://www.youtube.com/feeds/videos.xml?channel_id=$channelId';
    final response = await http.get(Uri.parse(url));
    if (response.statusCode == 200) {
      return parseRssFeed(response.body);
    } else {
      throw Exception('Failed to load RSS feed');
    }
  }

  /// Search for YouTube channels by name
  /// Returns a list of Channel objects with id and name
  static Future<List<Channel>> searchChannels(String query) async {
    if (query.trim().isEmpty) {
      return [];
    }

    try {
      // Use YouTube Data API v3 to search for channels
      final url = Uri.parse(
        'https://www.googleapis.com/youtube/v3/search'
        '?part=snippet'
        '&q=${Uri.encodeComponent(query)}'
        '&type=channel'
        '&maxResults=10'
        '&key=$_apiKey'
      );

      final response = await http.get(url);
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final items = data['items'] as List<dynamic>;
        
        return items.map((item) {
          final snippet = item['snippet'];
          return Channel(
            id: item['id']['channelId'],
            name: snippet['channelTitle'],
            description: snippet['description'] ?? '',
            thumbnailUrl: snippet['thumbnails']['default']['url'] ?? '',
          );
        }).toList();
      } else {
        print('YouTube API error: ${response.statusCode} - ${response.body}');
        return [];
      }
    } catch (e) {
      print('Error searching channels: $e');
      return [];
    }
  }

  /// Alternative method using web scraping when API key is not available
  /// This is a fallback method that doesn't require an API key
  static Future<List<Channel>> searchChannelsWebScraping(String query) async {
    if (query.trim().isEmpty) {
      return [];
    }

    try {
      // Use YouTube search page to find channels
      final searchUrl = 'https://www.youtube.com/results?search_query=${Uri.encodeComponent(query)}&sp=EgIQAg%3D%3D'; // sp=EgIQAg%3D%3D filters to channels only
      
      final response = await http.get(
        Uri.parse(searchUrl),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
        },
      );

      if (response.statusCode == 200) {
        final html = response.body;
        final channels = <Channel>[];
        
        // Extract channel information from the search results
        // This regex pattern looks for channel data in the YouTube search results
        final channelPattern = RegExp(r'"channelId":"(UC[\w-]{21,})".*?"title":"([^"]+)"', dotAll: true);
        final matches = channelPattern.allMatches(html);
        
        for (final match in matches.take(10)) {
          final channelId = match.group(1);
          final channelName = match.group(2);
          
          if (channelId != null && channelName != null) {
            channels.add(Channel(
              id: channelId,
              name: channelName,
              description: '',
              thumbnailUrl: '',
            ));
          }
        }
        
        return channels;
      } else {
        print('YouTube search error: ${response.statusCode}');
        return [];
      }
    } catch (e) {
      print('Error searching channels via web scraping: $e');
      return [];
    }
  }

  /// Get channel suggestions based on user input
  /// This method tries the API first, then falls back to web scraping
  static Future<List<Channel>> getChannelSuggestions(String query) async {
    if (query.trim().isEmpty) {
      return [];
    }

    // Try API first if key is available
    if (_apiKey != 'YOUR_YOUTUBE_API_KEY') {
      final apiResults = await searchChannels(query);
      if (apiResults.isNotEmpty) {
        return apiResults;
      }
    }

    // Fallback to web scraping
    return await searchChannelsWebScraping(query);
  }
} 