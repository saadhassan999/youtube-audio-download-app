import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart' as xml;

class ResolvedChannel {
  const ResolvedChannel({
    required this.id,
    required this.name,
    this.thumbnailUrl,
    this.handle,
  });

  final String id;
  final String name;
  final String? thumbnailUrl;
  final String? handle;
}

/// Parses a YouTube channel ID from a URL, handle, or returns the ID directly.
/// Supports /channel/CHANNEL_ID, /@handle, direct channel IDs, and raw @handle.
Future<String> parseChannelId(String urlOrId) async {
  final resolved = await resolveChannelFromInput(urlOrId);
  return resolved.id;
}

/// Resolve a channel from a handle or URL, returning its ID, title, and avatar.
Future<ResolvedChannel> resolveChannelFromInput(String urlOrId) async {
  final trimmed = urlOrId.trim();
  if (trimmed.isEmpty) {
    throw Exception('Channel input is empty.');
  }

  final uriToFetch = _buildChannelPageUri(trimmed);
  final response = await http.get(
    uriToFetch,
    headers: const {
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    },
  );
  if (response.statusCode != 200) {
    throw Exception(
      'Failed to load channel page (HTTP ${response.statusCode}).',
    );
  }

  final finalUri = response.request?.url ?? uriToFetch;
  final html = response.body;

  final requestedHandle = _normalizeHandle(_extractHandleFromInput(trimmed));

  final metaFromInitial = _extractFromYtInitialData(html);
  final metaFromPlayer = metaFromInitial?.id != null
      ? metaFromInitial
      : _extractFromPlayerResponse(html);
  _ChannelMeta? meta = metaFromInitial ?? metaFromPlayer;

  meta ??= _extractFromCanonical(html, finalUri);

  if (meta == null || meta.id == null || meta.id!.isEmpty) {
    throw Exception('Could not resolve channel ID from "$urlOrId".');
  }

  // Validate handle if the user provided one.
  final resolvedHandle = _normalizeHandle(
    meta.handle ??
        _extractHandleFromUrl(finalUri) ??
        _extractHandleFromHtml(html),
  );
  if (requestedHandle != null) {
    if (resolvedHandle == null ||
        requestedHandle.toLowerCase() != resolvedHandle.toLowerCase()) {
      throw Exception(
        'Could not resolve channel handle reliably. Please try again.',
      );
    }
  }

  String name = meta.title ??
      _extractMetaContent(html, 'og:title') ??
      _extractMetaContent(html, 'twitter:title') ??
      '';

  String? thumbnailUrl = meta.avatarUrl ??
      _extractMetaContent(html, 'og:image') ??
      _extractMetaContent(html, 'twitter:image');

  if (name.isEmpty) {
    try {
      name = await fetchChannelName(meta.id!);
    } catch (_) {
      name = 'YouTube Channel';
    }
  }

  return ResolvedChannel(
    id: meta.id!,
    name: name,
    thumbnailUrl: thumbnailUrl,
    handle: resolvedHandle ?? requestedHandle,
  );
}

/// Helper function to fetch channel ID from a YouTube handle (e.g., @username)
Future<String?> fetchChannelIdFromHandle(String handle) async {
  final resolved = await resolveChannelFromInput(handle);
  return resolved.id;
}

Uri _buildChannelPageUri(String input) {
  final trimmed = input.trim();
  if (trimmed.startsWith('@')) {
    final handle = _cleanHandle(trimmed);
    return Uri.parse('https://www.youtube.com/$handle');
  }

  final parsed = Uri.tryParse(trimmed);
  if (parsed != null && parsed.host.isNotEmpty) {
    final scheme = parsed.scheme.isNotEmpty ? parsed.scheme : 'https';
    return Uri(
      scheme: scheme,
      host: parsed.host,
      path: parsed.path,
      fragment: '',
    );
  }

  if (_looksLikeChannelId(trimmed)) {
    return Uri.parse('https://www.youtube.com/channel/$trimmed');
  }

  final fallbackHandle =
      trimmed.startsWith('@') ? _cleanHandle(trimmed) : '@$trimmed';
  return Uri.parse('https://www.youtube.com/$fallbackHandle');
}

String _cleanHandle(String handle) =>
    '@${handle.replaceFirst('@', '').split('?').first.split('/').first.trim().toLowerCase()}';

String? _extractHandleFromInput(String input) {
  final trimmed = input.trim();
  if (trimmed.startsWith('@')) {
    return _cleanHandle(trimmed);
  }
  final uri = Uri.tryParse(trimmed);
  if (uri != null && uri.pathSegments.isNotEmpty) {
    final first = uri.pathSegments.first;
    if (first.startsWith('@')) {
      return _cleanHandle(first);
    }
  }
  return null;
}

bool _looksLikeChannelId(String value) =>
    value.startsWith('UC') && value.length >= 20;

String? _extractChannelIdFromUrl(Uri uri) {
  final segments = uri.pathSegments;
  final channelIdx = segments.indexWhere((segment) => segment == 'channel');
  if (channelIdx != -1 && channelIdx + 1 < segments.length) {
    final candidate = segments[channelIdx + 1];
    if (_looksLikeChannelId(candidate)) {
      return candidate;
    }
  }
  // Sometimes the path itself is the channel ID.
  if (segments.isNotEmpty && _looksLikeChannelId(segments.last)) {
    return segments.last;
  }
  return null;
}

String? _normalizeHandle(String? handle) {
  if (handle == null || handle.isEmpty) return null;
  final cleaned = handle.startsWith('@') ? handle : '@$handle';
  return cleaned.trim().toLowerCase();
}

class _ChannelMeta {
  _ChannelMeta({this.id, this.title, this.handle, this.avatarUrl});

  final String? id;
  final String? title;
  final String? handle;
  final String? avatarUrl;
}

_ChannelMeta? _extractFromYtInitialData(String html) {
  final jsonStr = _extractJsonBlock(html, 'ytInitialData');
  if (jsonStr == null) return null;
  try {
    final data = json.decode(jsonStr) as Map<String, dynamic>;
    final metadata = data['metadata']?['channelMetadataRenderer']
        as Map<String, dynamic>?;
    if (metadata == null) return null;

    final id = metadata['externalId'] as String?;
    final vanity = metadata['vanityChannelUrl'] as String?;
    final handle =
        vanity != null && vanity.startsWith('/@') ? '@${vanity.substring(2)}' : null;

    final title = metadata['title'] as String?;
    final avatarUrl = _pickBestThumbnail(
      metadata['avatar']?['thumbnails'],
    );

    if (id != null && id.isNotEmpty) {
      return _ChannelMeta(
        id: id,
        title: title,
        handle: _normalizeHandle(handle),
        avatarUrl: avatarUrl,
      );
    }
  } catch (_) {
    return null;
  }
  return null;
}

_ChannelMeta? _extractFromPlayerResponse(String html) {
  final jsonStr = _extractJsonBlock(html, 'ytInitialPlayerResponse');
  if (jsonStr == null) return null;
  try {
    final data = json.decode(jsonStr) as Map<String, dynamic>;
    final micro = data['microformat']?['playerMicroformatRenderer']
        as Map<String, dynamic>?;
    if (micro == null) return null;
    final id = micro['externalChannelId'] as String?;
    final title = micro['ownerChannelName'] as String?;
    if (id != null && id.isNotEmpty) {
      return _ChannelMeta(id: id, title: title);
    }
  } catch (_) {
    return null;
  }
  return null;
}

_ChannelMeta? _extractFromCanonical(String html, Uri finalUri) {
  // Canonical or og:url pointing to /channel/UC...
  final canonicalUrl =
      _extractMetaContent(html, 'og:url') ?? _extractMetaContent(html, 'canonical');
  if (canonicalUrl != null) {
    final uri = Uri.tryParse(canonicalUrl);
    final id = _extractChannelIdFromUrl(uri ?? finalUri);
    if (id != null) {
      return _ChannelMeta(
        id: id,
        title: _extractMetaContent(html, 'og:title'),
        handle: _extractHandleFromUrl(uri),
        avatarUrl: _extractMetaContent(html, 'og:image'),
      );
    }
  }

  // Scoped browseId within initial data block.
  final scoped = _extractJsonBlock(html, 'ytInitialData');
  if (scoped != null) {
    final match = RegExp(r'"browseId":"(UC[\w-]{21,})"').firstMatch(scoped);
    if (match != null) {
      return _ChannelMeta(id: match.group(1));
    }
  }
  return null;
}

String? _extractHandleFromHtml(String html) {
  final canonicalBase = RegExp(
    r'"canonicalBaseUrl":"\\?/\\?(@[^"\\]+)"',
  ).firstMatch(html);
  if (canonicalBase != null) {
    return canonicalBase.group(1);
  }

  final ogUrl = _extractMetaContent(html, 'og:url');
  if (ogUrl != null) {
    final uri = Uri.tryParse(ogUrl);
    return _extractHandleFromUrl(uri);
  }
  return null;
}

String? _extractHandleFromUrl(Uri? uri) {
  if (uri == null) return null;
  final segments = uri.pathSegments;
  if (segments.isNotEmpty && segments.first.startsWith('@')) {
    return segments.first;
  }
  return null;
}

String? _extractMetaContent(String html, String propertyName) {
  final pattern = RegExp(
    '<meta[^>]+(?:property|name)=[\'"]$propertyName[\'"][^>]*content=[\'"]([^\'"]+)[\'"][^>]*>',
    caseSensitive: false,
  );
  final match = pattern.firstMatch(html);
  return match?.group(1);
}

String? _extractJsonBlock(String html, String marker) {
  final idx = html.indexOf(marker);
  if (idx == -1) return null;
  final start = html.indexOf('{', idx);
  if (start == -1) return null;

  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var i = start; i < html.length; i++) {
    final char = html[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (char == '\\') {
      escaped = true;
      continue;
    }
    if (char == '"') {
      inString = !inString;
      continue;
    }
    if (inString) continue;

    if (char == '{') depth++;
    if (char == '}') depth--;
    if (depth == 0) {
      return html.substring(start, i + 1);
    }
  }
  return null;
}

String? _pickBestThumbnail(dynamic thumbnailsNode) {
  if (thumbnailsNode is List && thumbnailsNode.isNotEmpty) {
    final last = thumbnailsNode.last;
    if (last is Map<String, dynamic>) {
      return last['url'] as String? ??
          last['thumbnailUrl'] as String?;
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

final RegExp _videoIdPattern = RegExp(r'^[a-zA-Z0-9_-]{11}$');

String? tryParseVideoId(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return null;

  if (_videoIdPattern.hasMatch(trimmed)) {
    return trimmed;
  }

  final maybeUri = Uri.tryParse(trimmed);
  if (maybeUri != null && maybeUri.host.isNotEmpty) {
    final host = maybeUri.host.toLowerCase();
    final segments = maybeUri.pathSegments;

    if (host.contains('youtu.be') && segments.isNotEmpty) {
      final candidate = segments.first;
      if (_videoIdPattern.hasMatch(candidate)) {
        return candidate;
      }
    }

    if (host.contains('youtube.com')) {
      final queryId = maybeUri.queryParameters['v'];
      if (queryId != null && _videoIdPattern.hasMatch(queryId)) {
        return queryId;
      }

      if (segments.length >= 2) {
        final type = segments.first;
        final candidate = segments[1];
        if ((type == 'embed' || type == 'shorts' || type == 'live') &&
            _videoIdPattern.hasMatch(candidate)) {
          return candidate;
        }
      }
    }
  }

  final embeddedMatch =
      RegExp(r'(?<![a-zA-Z0-9_-])([a-zA-Z0-9_-]{11})(?![a-zA-Z0-9_-])')
          .firstMatch(trimmed);
  if (embeddedMatch != null) {
    return embeddedMatch.group(1);
  }

  return null;
}

bool looksLikeVideoUrlOrId(String input) => tryParseVideoId(input) != null;
