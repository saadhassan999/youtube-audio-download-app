import 'video.dart';

class SavedVideo {
  final int? id;
  final String videoId;
  final String title;
  final String channelId;
  final String channelTitle;
  final Duration? duration;
  final String thumbnailUrl;
  final DateTime? publishedAt;
  final DateTime savedAtUtc;
  final String status;
  final String? localPath;
  final int? bytesTotal;
  final int? bytesDownloaded;

  SavedVideo({
    this.id,
    required this.videoId,
    required this.title,
    required this.channelId,
    required this.channelTitle,
    this.duration,
    required this.thumbnailUrl,
    this.publishedAt,
    required this.savedAtUtc,
    required this.status,
    this.localPath,
    this.bytesTotal,
    this.bytesDownloaded,
  });

  SavedVideo copyWith({
    int? id,
    String? videoId,
    String? title,
    String? channelId,
    String? channelTitle,
    Duration? duration,
    String? thumbnailUrl,
    DateTime? publishedAt,
    DateTime? savedAtUtc,
    String? status,
    String? localPath,
    int? bytesTotal,
    int? bytesDownloaded,
  }) {
    return SavedVideo(
      id: id ?? this.id,
      videoId: videoId ?? this.videoId,
      title: title ?? this.title,
      channelId: channelId ?? this.channelId,
      channelTitle: channelTitle ?? this.channelTitle,
      duration: duration ?? this.duration,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      publishedAt: publishedAt ?? this.publishedAt,
      savedAtUtc: savedAtUtc ?? this.savedAtUtc,
      status: status ?? this.status,
      localPath: localPath ?? this.localPath,
      bytesTotal: bytesTotal ?? this.bytesTotal,
      bytesDownloaded: bytesDownloaded ?? this.bytesDownloaded,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'videoId': videoId,
        'title': title,
        'channelId': channelId,
        'channelTitle': channelTitle,
        'durationMs': duration?.inMilliseconds,
        'thumbnailUrl': thumbnailUrl,
        'publishedAt': publishedAt?.toIso8601String(),
        'savedAtUtc': savedAtUtc.toIso8601String(),
        'status': status,
        'localPath': localPath,
        'bytesTotal': bytesTotal,
        'bytesDownloaded': bytesDownloaded,
      };

  factory SavedVideo.fromMap(Map<String, dynamic> map) => SavedVideo(
        id: map['id'] as int?,
        videoId: map['videoId'] as String,
        title: map['title'] as String,
        channelId: map['channelId'] as String,
        channelTitle: map['channelTitle'] as String,
        duration: map['durationMs'] != null
            ? Duration(milliseconds: map['durationMs'] as int)
            : null,
        thumbnailUrl: map['thumbnailUrl'] as String? ?? '',
        publishedAt: map['publishedAt'] != null
            ? DateTime.parse(map['publishedAt'] as String)
            : null,
        savedAtUtc: DateTime.parse(map['savedAtUtc'] as String),
        status: map['status'] as String? ?? 'saved',
        localPath: map['localPath'] as String?,
        bytesTotal: map['bytesTotal'] as int?,
        bytesDownloaded: map['bytesDownloaded'] as int?,
      );

  static SavedVideo fromVideo(
    Video video, {
    DateTime? savedAt,
    String status = 'saved',
  }) {
    return SavedVideo(
      videoId: video.id,
      title: video.title,
      channelId: video.channelId ?? '',
      channelTitle: video.channelName,
      duration: video.duration,
      thumbnailUrl: video.thumbnailUrl,
      publishedAt: video.published,
      savedAtUtc: savedAt ?? DateTime.now().toUtc(),
      status: status,
    );
  }
}
