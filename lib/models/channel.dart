class Channel {
  final String id;
  final String name;
  final String description;
  final String thumbnailUrl;
  String lastVideoId;

  Channel({
    required this.id, 
    required this.name, 
    this.description = '',
    this.thumbnailUrl = '',
    this.lastVideoId = ''
  });

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
  );
} 