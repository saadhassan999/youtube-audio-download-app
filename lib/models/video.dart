class Video {
  final String id;
  final String title;
  final DateTime published;
  final String thumbnailUrl;
  final String channelName;

  Video({
    required this.id,
    required this.title,
    required this.published,
    required this.thumbnailUrl,
    required this.channelName,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'title': title,
    'published': published.toIso8601String(),
    'thumbnailUrl': thumbnailUrl,
    'channelName': channelName,
  };

  factory Video.fromMap(Map<String, dynamic> map) => Video(
    id: map['id'],
    title: map['title'],
    published: DateTime.parse(map['published']),
    thumbnailUrl: map['thumbnailUrl'],
    channelName: map['channelName'],
  );
} 