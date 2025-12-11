import 'package:flutter/foundation.dart';

import '../services/youtube_api_service.dart';

class ChannelUploadsController extends ChangeNotifier {
  ChannelUploadsController({required this.api, required this.channelId});

  final YoutubeApiService api;
  final String channelId;

  String? _uploadsPlaylistId;
  final List<VideoItem> _videos = [];
  String? _nextPageToken;
  bool _initializing = false;
  bool _loadingMore = false;
  ChannelRefreshException? _error;

  List<VideoItem> get videos => List.unmodifiable(_videos);
  bool get isInitializing => _initializing;
  bool get isLoadingMore => _loadingMore;
  bool get hasMore => _nextPageToken != null;
  ChannelRefreshException? get error => _error;

  Future<void> ensureInitialized() async {
    if (_uploadsPlaylistId != null || _initializing) return;
    _initializing = true;
    _error = null;
    notifyListeners();

    try {
      _uploadsPlaylistId = await api.getUploadsPlaylistId(channelId);
      if (_uploadsPlaylistId == null) {
        throw Exception('Uploads playlist not found for $channelId');
      }
      await _loadNextPageInternal(resetError: false);
    } catch (e, stack) {
      _recordError(e, stack);
    } finally {
      _initializing = false;
      notifyListeners();
    }
  }

  Future<void> loadNextPage() async {
    if (_loadingMore || !hasMore || _uploadsPlaylistId == null) return;
    await _loadNextPageInternal(resetError: true);
  }

  Future<void> _loadNextPageInternal({required bool resetError}) async {
    if (_uploadsPlaylistId == null) return;
    _loadingMore = true;
    if (resetError) {
      _error = null;
    }
    notifyListeners();

    try {
      final page = await api.fetchUploadsPage(
        uploadsPlaylistId: _uploadsPlaylistId!,
        pageToken: _nextPageToken,
      );
      _videos.addAll(page.videos);
      _nextPageToken = page.nextPageToken;
    } catch (e, stack) {
      _recordError(e, stack);
    } finally {
      _loadingMore = false;
      notifyListeners();
    }
  }

  void reset() {
    _uploadsPlaylistId = null;
    _videos.clear();
    _nextPageToken = null;
    _initializing = false;
    _loadingMore = false;
    _error = null;
    notifyListeners();
  }

  void _recordError(Object error, StackTrace stackTrace) {
    final wrapped = error is ChannelRefreshException
        ? error
        : ChannelRefreshException(
            message: 'Unable to refresh channel uploads.',
            isOffline: ChannelRefreshException.isNetworkError(error),
            cause: error,
            stackTrace: stackTrace,
          );

    _error = wrapped;

    final tag = wrapped.isOffline
        ? '[ChannelRefresh] Network error'
        : '[ChannelRefresh] API error';
    debugPrint(
      '$tag for channel $channelId: ${wrapped.cause ?? wrapped.message}',
    );
    final logStack = wrapped.stackTrace ?? stackTrace;
    debugPrint('$tag stack: $logStack');
  }
}
