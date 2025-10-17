import 'package:http/http.dart' as http;
import 'package:xml/xml.dart' as xml;

/// Parses a YouTube channel ID from a URL, handle, or returns the ID directly.
/// Supports /channel/CHANNEL_ID, /@handle, direct channel IDs, and raw @handle.
Future<String> parseChannelId(String urlOrId) async {
  // If it's a raw handle (starts with @)
  if (urlOrId.trim().startsWith('@')) {
    final channelId = await fetchChannelIdFromHandle(urlOrId.trim());
    if (channelId != null) {
      return channelId;
    } else {
      throw Exception('Could not resolve handle "$urlOrId" to channel ID.');
    }
  }

  final uri = Uri.tryParse(urlOrId);

  if (uri != null && uri.host.contains('youtube.com')) {
    // Channel URL: /channel/CHANNEL_ID
    if (uri.pathSegments.contains('channel')) {
      return uri.pathSegments.last;
    }
    // Handle URL: /@handle
    else if (uri.pathSegments.isNotEmpty &&
        uri.pathSegments.first.startsWith('@')) {
      // Only use the first path segment as the handle, ignore query and extra path
      final handle = uri.pathSegments.first;
      final channelId = await fetchChannelIdFromHandle(handle);
      if (channelId != null) {
        return channelId;
      } else {
        throw Exception('Could not resolve handle "$handle" to channel ID.');
      }
    }
    // User URL (not supported)
    else if (uri.pathSegments.contains('user')) {
      throw Exception(
        'User URLs not supported. Please use channel URLs or handles.',
      );
    }
  }
  // Otherwise, assume it's already a channel ID
  return urlOrId;
}

/// Helper function to fetch channel ID from a YouTube handle (e.g., @username)
Future<String?> fetchChannelIdFromHandle(String handle) async {
  // Remove any query parameters or slashes from handle
  final cleanHandle = handle.split('?').first.split('/').first;
  final url = 'https://www.youtube.com/$cleanHandle';

  // Use a desktop user-agent to get the standard HTML
  final response = await http.get(
    Uri.parse(url),
    headers: {
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    },
  );

  if (response.statusCode == 200) {
    final html = response.body;

    // Try multiple patterns for robustness
    final patterns = [
      RegExp(r'"channelId":"(UC[\w-]{21,})"'), // JSON in HTML
      RegExp(r'www\.youtube\.com/channel/(UC[\w-]{21,})'), // canonical link
      RegExp(r'channelId=\\?"(UC[\w-]{21,})\\?"'), // sometimes escaped
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(html);
      if (match != null) {
        return match.group(1);
      }
    }
  }
  return null;
}

/// Fetches the channel name from a channel ID using the YouTube RSS feed.
Future<String> fetchChannelName(String channelId) async {
  final url = 'https://www.youtube.com/feeds/videos.xml?channel_id=$channelId';
  final response = await http.get(Uri.parse(url));
  if (response.statusCode == 200) {
    final document = xml.XmlDocument.parse(response.body);
    final titleElement = document.findAllElements('title').first;
    return titleElement.innerText;
  } else {
    throw Exception('Failed to fetch channel name');
  }
}

String formatSubscriberCount(int? count) {
  if (count == null) return '';
  if (count >= 1000000000) {
    return _formatWithSuffix(count, 1000000000, 'B');
  }
  if (count >= 1000000) {
    return _formatWithSuffix(count, 1000000, 'M');
  }
  if (count >= 1000) {
    return _formatWithSuffix(count, 1000, 'K');
  }
  return count.toString();
}

String _formatWithSuffix(int count, int divisor, String suffix) {
  final value = count / divisor;
  final formatted = value.toStringAsFixed(2);
  final trimmed = formatted.replaceFirst(RegExp(r'\.?0+$'), '');
  return '$trimmed$suffix';
}
