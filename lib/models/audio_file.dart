class AudioFile {
  final int? id;
  final String title;
  final String channelName;
  final String filePath;
  final String videoId;
  final int? playlistId;
  final String thumbnailUrl;

  AudioFile({
    this.id,
    required this.title,
    required this.channelName,
    required this.filePath,
    required this.videoId,
    this.playlistId,
    this.thumbnailUrl = '',
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'title': title,
    'channelName': channelName,
    'filePath': filePath,
    'videoId': videoId,
    'playlistId': playlistId,
    'thumbnailUrl': thumbnailUrl,
  };

  factory AudioFile.fromMap(Map<String, dynamic> map) => AudioFile(
    id: map['id'],
    title: map['title'],
    channelName: map['channelName'],
    filePath: map['filePath'],
    videoId: map['videoId'],
    playlistId: map['playlistId'],
    thumbnailUrl: map['thumbnailUrl'] ?? '',
  );
} 