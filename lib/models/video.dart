class Video {
  final String id;
  final String title;
  final DateTime published;
  final String thumbnailUrl;
  final String channelName;
  final String? channelId;
  final Duration? duration;

  Video({
    required this.id,
    required this.title,
    required this.published,
    required this.thumbnailUrl,
    required this.channelName,
    this.channelId,
    this.duration,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'published': published.toIso8601String(),
        'thumbnailUrl': thumbnailUrl,
        'channelName': channelName,
        'channelId': channelId,
        'durationMs': duration?.inMilliseconds,
      };

  factory Video.fromMap(Map<String, dynamic> map) => Video(
        id: map['id'],
        title: map['title'],
        published: DateTime.parse(map['published']),
        thumbnailUrl: map['thumbnailUrl'],
        channelName: map['channelName'],
        channelId: map['channelId'],
        duration: map['durationMs'] != null
            ? Duration(milliseconds: map['durationMs'])
            : null,
      );
}
