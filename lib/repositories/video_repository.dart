import 'dart:async';

import '../models/saved_video.dart';
import '../models/video.dart';
import '../services/database_service.dart';

class VideoRepository {
  VideoRepository._();

  static final VideoRepository instance = VideoRepository._();

  final _controller = StreamController<List<SavedVideo>>.broadcast();
  List<SavedVideo> _cache = const [];
  bool _isRefreshing = false;
  bool _initialized = false;
  bool _disposed = false;

  Stream<List<SavedVideo>> watchSavedVideos() {
    if (!_initialized) {
      _initialized = true;
      unawaited(_refresh());
    }
    return _controller.stream;
  }

  Future<void> upsertSavedVideo(Video video) async {
    final existing =
        await DatabaseService.instance.getSavedVideo(video.id);
    final now = DateTime.now().toUtc();
    final status = existing?.status ?? 'saved';
    var savedVideo = SavedVideo.fromVideo(
      video,
      savedAt: now,
      status: status,
    );

    if ((video.channelId == null || video.channelId!.isEmpty) &&
        existing?.channelId.isNotEmpty == true) {
      savedVideo = savedVideo.copyWith(channelId: existing!.channelId);
    }

    if (savedVideo.channelTitle.isEmpty &&
        existing?.channelTitle.isNotEmpty == true) {
      savedVideo = savedVideo.copyWith(channelTitle: existing!.channelTitle);
    }

    if (savedVideo.thumbnailUrl.isEmpty &&
        existing?.thumbnailUrl.isNotEmpty == true) {
      savedVideo = savedVideo.copyWith(thumbnailUrl: existing!.thumbnailUrl);
    }

    if (savedVideo.duration == null && existing?.duration != null) {
      savedVideo = savedVideo.copyWith(duration: existing!.duration);
    }

    if (savedVideo.publishedAt == null && existing?.publishedAt != null) {
      savedVideo = savedVideo.copyWith(publishedAt: existing!.publishedAt);
    }

    savedVideo = savedVideo.copyWith(
      id: existing?.id,
      localPath: existing?.localPath,
      bytesTotal: existing?.bytesTotal,
      bytesDownloaded: existing?.bytesDownloaded,
    );

    await DatabaseService.instance.upsertSavedVideo(savedVideo);
    await _refresh();
  }

  Future<void> markSavedVideoAsDownloading(
    String videoId, {
    int? bytesTotal,
    int? bytesDownloaded,
  }) async {
    await DatabaseService.instance.updateSavedVideoFields(videoId, {
      'status': 'downloading',
      if (bytesTotal != null) 'bytesTotal': bytesTotal,
      if (bytesDownloaded != null) 'bytesDownloaded': bytesDownloaded,
    });
    await _refresh();
  }

  Future<void> updateSavedVideoProgress(
    String videoId, {
    int? bytesTotal,
    int? bytesDownloaded,
  }) async {
    await DatabaseService.instance.updateSavedVideoFields(videoId, {
      if (bytesTotal != null) 'bytesTotal': bytesTotal,
      if (bytesDownloaded != null) 'bytesDownloaded': bytesDownloaded,
    });
    await _refresh();
  }

  Future<void> markSavedVideoAsDownloaded(
    String videoId,
    String localPath,
    int bytesTotal,
  ) async {
    await DatabaseService.instance.updateSavedVideoFields(videoId, {
      'status': 'downloaded',
      'localPath': localPath,
      'bytesTotal': bytesTotal,
      'bytesDownloaded': bytesTotal,
    });
    await _refresh();
  }

  Future<void> markSavedVideoAsError(String videoId) async {
    await DatabaseService.instance.updateSavedVideoFields(videoId, {
      'status': 'error',
    });
    await _refresh();
  }

  Future<void> resetSavedVideo(String videoId) async {
    await DatabaseService.instance.updateSavedVideoFields(videoId, {
      'status': 'saved',
      'bytesTotal': null,
      'bytesDownloaded': null,
      'localPath': null,
    });
    await _refresh();
  }

  Future<void> removeSavedVideo(String videoId) async {
    await DatabaseService.instance.deleteSavedVideo(videoId);
    await _refresh();
  }

  SavedVideo? getFromCache(String videoId) {
    try {
      return _cache.firstWhere((element) => element.videoId == videoId);
    } catch (_) {
      return null;
    }
  }

  Future<void> _refresh() async {
    if (_disposed) return;
    if (_isRefreshing) return;
    _isRefreshing = true;
    try {
      final items = await DatabaseService.instance.getSavedVideos();
      _cache = items;
      if (!_controller.isClosed) {
        _controller.add(List.unmodifiable(items));
      }
    } finally {
      _isRefreshing = false;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _controller.close();
  }
}
