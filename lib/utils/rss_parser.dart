import 'package:xml/xml.dart' as xml;
import '../models/video.dart';

List<Video> parseRssFeed(String xmlString) {
  final document = xml.XmlDocument.parse(xmlString);
  final entries = document.findAllElements('entry');
  return entries.map((entry) {
    final id = entry.findElements('yt:videoId').isNotEmpty
        ? entry.findElements('yt:videoId').first.text
        : '';
    final title = entry.findElements('title').isNotEmpty
        ? entry.findElements('title').first.text
        : '';
    final published = entry.findElements('published').isNotEmpty
        ? DateTime.parse(entry.findElements('published').first.text)
        : DateTime.now();
    final mediaGroup = entry.findElements('media:group').isNotEmpty
        ? entry.findElements('media:group').first
        : null;
    final thumbnailUrl = mediaGroup != null &&
            mediaGroup.findElements('media:thumbnail').isNotEmpty
        ? mediaGroup
                .findElements('media:thumbnail')
                .first
                .getAttribute('url') ??
            ''
        : '';
    final channelName = entry.findElements('author').isNotEmpty
        ? entry.findElements('author').first.findElements('name').first.text
        : '';
    final channelId = entry.findElements('yt:channelId').isNotEmpty
        ? entry.findElements('yt:channelId').first.text
        : null;
    Duration? duration;
    if (mediaGroup != null) {
      final durationElement = mediaGroup.findElements('yt:duration').isNotEmpty
          ? mediaGroup.findElements('yt:duration').first
          : null;
      final seconds = durationElement?.getAttribute('seconds');
      if (seconds != null) {
        final value = int.tryParse(seconds);
        if (value != null) {
          duration = Duration(seconds: value);
        }
      }
    }
    return Video(
      id: id,
      title: title,
      published: published,
      thumbnailUrl: thumbnailUrl,
      channelName: channelName,
      channelId: channelId,
      duration: duration,
    );
  }).toList();
}
