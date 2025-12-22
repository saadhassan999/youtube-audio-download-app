import '../utils/youtube_utils.dart';

class Channel {
  final String id;
  final String name;
  final String description;
  final String thumbnailUrl;
  final String? handle;
  final int? subscriberCount;
  final bool hiddenSubscriberCount;
  String lastVideoId;

  Channel({
    required this.id,
    required this.name,
    this.description = '',
    this.thumbnailUrl = '',
    this.lastVideoId = '',
    this.handle,
    this.subscriberCount,
    this.hiddenSubscriberCount = false,
  });

  String get formattedSubscribers {
    if (hiddenSubscriberCount) {
      return 'Subscribers hidden';
    }

    if (subscriberCount == null) {
      return '— subscribers';
    }

    final formatted = formatSubscriberCount(subscriberCount);
    final label = formatted.isNotEmpty ? formatted : subscriberCount.toString();
    return '$label subscribers';
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'description': description,
    'thumbnailUrl': thumbnailUrl,
    'lastVideoId': lastVideoId,
  };

  factory Channel.fromMap(Map<String, dynamic> map) => Channel(
    id: map['id'],
    name: map['name'],
    description: map['description'] ?? '',
    thumbnailUrl: map['thumbnailUrl'] ?? '',
    lastVideoId: map['lastVideoId'] ?? '',
    handle: map['handle'],
    subscriberCount: map['subscriberCount'],
    hiddenSubscriberCount: map['hiddenSubscriberCount'] ?? false,
  );
}
