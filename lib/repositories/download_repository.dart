import '../models/downloaded_video.dart';
import '../services/database_service.dart';

class DownloadRepository {
  DownloadRepository._();

  static final DownloadRepository instance = DownloadRepository._();

  List<DownloadedVideo> _cache = const [];
  bool _hasCache = false;
  Future<List<DownloadedVideo>>? _inFlight;

  List<DownloadedVideo> get cached => List.unmodifiable(_cache);

  Future<List<DownloadedVideo>> fetchDownloads({
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _hasCache) {
      return List.unmodifiable(_cache);
    }

    final inFlight = _inFlight;
    if (inFlight != null) {
      final downloads = await inFlight;
      return List.unmodifiable(downloads);
    }

    final future = _loadFromDatabase();
    _inFlight = future;
    try {
      final downloads = await future;
      _cache = downloads;
      _hasCache = true;
      return List.unmodifiable(downloads);
    } finally {
      _inFlight = null;
    }
  }

  void replaceCache(List<DownloadedVideo> downloads) {
    _cache = List.unmodifiable(downloads);
    _hasCache = true;
  }

  void invalidate() {
    _cache = const [];
    _hasCache = false;
  }

  Future<List<DownloadedVideo>> _loadFromDatabase() async {
    final videos = await DatabaseService.instance.getDownloadedVideos();
    return List.unmodifiable(videos);
  }
}
