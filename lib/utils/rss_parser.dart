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
    final thumbnailUrl = entry.findElements('media:group').isNotEmpty
        ? entry.findElements('media:group').first.findElements('media:thumbnail').first.getAttribute('url') ?? ''
        : '';
    final channelName = entry.findElements('author').isNotEmpty
        ? entry.findElements('author').first.findElements('name').first.text
        : '';
    return Video(
      id: id,
      title: title,
      published: published,
      thumbnailUrl: thumbnailUrl,
      channelName: channelName,
    );
  }).toList();
} 