class DownloadedVideo {
  final String videoId;
  final String title;
  final String filePath;
  final int size;
  final Duration? duration;
  final String channelName;
  final String thumbnailUrl;
  final DateTime downloadedAt;
  final String status; // e.g., 'completed', 'downloading', 'failed'

  DownloadedVideo({
    required this.videoId,
    required this.title,
    required this.filePath,
    required this.size,
    this.duration,
    required this.channelName,
    required this.thumbnailUrl,
    required this.downloadedAt,
    required this.status,
  });

  Map<String, dynamic> toMap() => {
    'videoId': videoId,
    'title': title,
    'filePath': filePath,
    'size': size,
    'duration': duration?.inSeconds,
    'channelName': channelName,
    'thumbnailUrl': thumbnailUrl,
    'downloadedAt': downloadedAt.toIso8601String(),
    'status': status,
  };

  factory DownloadedVideo.fromMap(Map<String, dynamic> map) => DownloadedVideo(
    videoId: map['videoId'],
    title: map['title'],
    filePath: map['filePath'],
    size: map['size'],
    duration: map['duration'] != null ? Duration(seconds: map['duration']) : null,
    channelName: map['channelName'],
    thumbnailUrl: map['thumbnailUrl'],
    downloadedAt: DateTime.parse(map['downloadedAt']),
    status: map['status'],
  );
} 