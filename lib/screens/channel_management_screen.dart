import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import '../core/fetch_exception.dart';
import '../models/channel.dart';
import '../models/video.dart';
import '../models/saved_video.dart';
import '../models/downloaded_video.dart';
import '../repositories/channel_repository.dart';
import '../repositories/video_repository.dart';
import '../services/database_service.dart';
import '../services/download_service.dart';
import '../utils/youtube_utils.dart';
import '../widgets/channel_search_field.dart';
import '../widgets/mini_player.dart';
import '../widgets/channel_video_tile.dart';
import '../core/snackbar_bus.dart';
import 'download_manager_screen.dart';
import 'package:sqflite/sqflite.dart';
import 'dart:async';

class ChannelManagementScreen extends StatefulWidget {
  const ChannelManagementScreen({super.key});
  @override
  State<ChannelManagementScreen> createState() =>
      _ChannelManagementScreenState();
}

class _ChannelManagementScreenState extends State<ChannelManagementScreen>
    with SingleTickerProviderStateMixin {
  final ChannelRepository _channelRepository = ChannelRepository.instance;
  final Map<String, _ChannelSectionState> _channelStates = {};
  final Map<String, Future<void>> _channelRefreshes = {};
  List<Channel> _channels = [];
  List<SavedVideo> _savedVideos = [];
  bool _isRefreshingAll = false;
  bool _isOnline = true;
  late AnimationController _logoController;
  final _scroll = ScrollController();
  StreamSubscription<dynamic>? _connectivitySub;
  StreamSubscription<List<SavedVideo>>? _savedVideosSub;

  void _openDownloads() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => DownloadManagerScreen()),
    );
  }

  Future<void> _initConnectivity() async {
    final connectivity = Connectivity();
    final initial = await connectivity.checkConnectivity();
    _updateConnectivityStatus(
      _isConnected(initial),
      silent: true,
    );
    _connectivitySub = connectivity.onConnectivityChanged.listen(
      (event) => _updateConnectivityStatus(
        _isConnected(event),
      ),
    );
  }

  bool _isConnected(dynamic value) {
    if (value is ConnectivityResult) {
      return value != ConnectivityResult.none;
    }
    if (value is List<ConnectivityResult>) {
      return value.any((result) => result != ConnectivityResult.none);
    }
    return false;
  }

  void _updateConnectivityStatus(bool isOnline, {bool silent = false}) {
    if (!mounted || _isOnline == isOnline) {
      return;
    }
    setState(() {
      _isOnline = isOnline;
    });
    if (isOnline && !silent) {
      showGlobalSnackBar(
        SnackBar(content: Text('Back online - pull to refresh.')),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    _logoController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 900),
    );
    _initConnectivity();
    _loadChannels();
    _savedVideosSub = VideoRepository.instance
        .watchSavedVideos()
        .listen((videos) {
      if (!mounted) return;
      setState(() {
        _savedVideos = videos;
      });
    });
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    _savedVideosSub?.cancel();
    _logoController.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadChannels() async {
    final channels = await DatabaseService.instance.getChannels();
    if (!mounted) return;
    setState(() {
      _channels = channels;
      _synchronizeChannelStatesWithCache();
    });

    for (final channel in channels) {
      final current = _channelStates[channel.id];
      if (current == null || current.videos.isEmpty) {
        unawaited(_refreshChannel(channel.id));
      }
    }
  }

  Future<void> _addChannel(String urlOrId) async {
    try {
      String channelId = await parseChannelId(urlOrId);
      String channelName = await fetchChannelName(channelId);
      await DatabaseService.instance.addChannel(
        Channel(
          id: channelId,
          name: channelName,
          lastVideoId:
              '', // Set empty lastVideoId so background task processes all videos initially
        ),
      );
      await _loadChannels();
      await _refreshChannel(channelId, forceRefresh: true);
      if (!mounted) return;
      showGlobalSnackBar(
        SnackBar(content: Text('Channel added: $channelName')),
      );
    } catch (e) {
      if (!mounted) return;
      showGlobalSnackBar(SnackBar(content: Text('Failed to add channel: $e')));
    }
  }

  void _onChannelSelected(Channel channel) async {
    await _loadChannels();
    await _refreshChannel(channel.id, forceRefresh: true);
    if (!mounted) return;
      showGlobalSnackBar(
        SnackBar(content: Text('Channel added: ${channel.name}')),
      );
  }

  void _synchronizeChannelStatesWithCache() {
    final ids = _channels.map((c) => c.id).toSet();
    _channelStates.removeWhere((key, _) => !ids.contains(key));

    for (final channel in _channels) {
      final cachedVideos = _channelRepository.getCachedVideos(channel.id);
      final isStale = _channelRepository.isStale(channel.id);
      final existing = _channelStates[channel.id];

      if (existing == null) {
        _channelStates[channel.id] = _ChannelSectionState(
          videos: cachedVideos,
          isLoadingInitial: cachedVideos.isEmpty,
          isStale: isStale,
        );
      } else {
        _channelStates[channel.id] = existing.copyWith(
          videos: cachedVideos.isNotEmpty ? cachedVideos : existing.videos,
          isStale: isStale,
        );
      }
    }
  }

  Future<void> _refreshAll({bool forceRefresh = true}) async {
    if (_isRefreshingAll || _channels.isEmpty) return;
    setState(() {
      _isRefreshingAll = true;
    });

    try {
      await Future.wait(
        _channels.map(
          (channel) => _refreshChannel(
            channel.id,
            forceRefresh: forceRefresh,
          ),
        ),
      );
    } finally {
      if (!mounted) return;
      setState(() {
        _isRefreshingAll = false;
      });
    }
  }

  Future<void> _refreshChannel(
    String channelId, {
    bool forceRefresh = false,
  }) {
    final inFlight = _channelRefreshes[channelId];
    if (inFlight != null) return inFlight;

    final future = _doRefreshChannel(
      channelId,
      forceRefresh: forceRefresh,
    );
    _channelRefreshes[channelId] = future;
    return future.whenComplete(() {
      _channelRefreshes.remove(channelId);
    });
  }

  Future<void> _doRefreshChannel(
    String channelId, {
    required bool forceRefresh,
  }) async {
    final current = _channelStates[channelId] ??
        const _ChannelSectionState(isLoadingInitial: true);

    final next = current.copyWith(
      isLoadingInitial: current.videos.isEmpty,
      isRefreshing: current.videos.isNotEmpty,
      clearError: true,
    );
    _setChannelState(channelId, next);

    try {
      final result = await _channelRepository.fetchChannelVideos(
        channelId,
        forceRefresh: forceRefresh,
      );
      final updated = (_channelStates[channelId] ?? next).copyWith(
        videos: result.videos,
        isLoadingInitial: false,
        isRefreshing: false,
        isStale: false,
        clearError: true,
      );
      _setChannelState(channelId, updated);
    } on FetchException catch (e) {
      final base = _channelStates[channelId] ?? current;
      final updated = base.copyWith(
        isLoadingInitial: false,
        isRefreshing: false,
        isStale: e.isOffline || base.isStale || base.videos.isEmpty,
        lastError: e,
      );
      _setChannelState(channelId, updated);
      if (e.isOffline) {
        showGlobalSnackBar(
          SnackBar(
            content: Text(
              'You\'re offline. Pull to refresh after reconnecting.',
            ),
          ),
        );
      } else {
        showGlobalSnackBar(
          SnackBar(
            content: Text(e.message.isNotEmpty
                ? e.message
                : 'Failed to load videos. Please try again.'),
          ),
        );
      }
    } catch (e) {
      final base = _channelStates[channelId] ?? current;
      final updated = base.copyWith(
        isLoadingInitial: false,
        isRefreshing: false,
        lastError: FetchException(message: e.toString()),
      );
      _setChannelState(channelId, updated);
      showGlobalSnackBar(
        SnackBar(
          content: Text('Failed to load videos. Please try again.'),
        ),
      );
    }
  }

  void _setChannelState(String channelId, _ChannelSectionState state) {
    if (!mounted) return;
    setState(() {
      _channelStates[channelId] = state;
    });
  }

  List<Widget> _buildSavedVideosSlivers() {
    if (_savedVideos.isEmpty) {
      return const [];
    }
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'Saved Videos',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
      SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final saved = _savedVideos[index];
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: SavedVideoTile(savedVideo: saved),
            );
          },
          childCount: _savedVideos.length,
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 16)),
    ];
  }

  Widget _buildInlineActionButton({
    required String label,
    required bool isBusy,
    required VoidCallback? onPressed,
  }) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        onPressed: onPressed == null
            ? null
            : () {
                if (isBusy) return;
                onPressed();
              },
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isBusy)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              const Icon(Icons.refresh, size: 18),
            const SizedBox(width: 6),
            Text(label),
          ],
        ),
      ),
    );
  }

  Widget _buildOfflineBanner() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        border: Border.all(color: Colors.orange.shade200),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Icon(Icons.wifi_off, color: Colors.orange.shade700),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              "You're offline. Pull to refresh after reconnecting.",
              style: TextStyle(color: Colors.orange.shade700),
            ),
          ),
        ],
      ),
    );
  }

  String _describeChannelMessage(
    _ChannelSectionState state,
    FetchException? error,
  ) {
    if (error != null) {
      if (error.isOffline) {
        return "You're offline. Pull to refresh after reconnecting.";
      }
      if (error.message.isNotEmpty) {
        return error.message;
      }
      return 'Unable to refresh videos right now.';
    }
    if (state.isStale) {
      return 'Last refresh failed. Pull to refresh.';
    }
    return 'No videos found.';
  }

  @override
  Widget build(BuildContext context) {
    final ime = MediaQuery.viewInsetsOf(context).bottom; // keyboard
    final safe = MediaQuery.paddingOf(context).bottom; // system nav
    final topSafe = MediaQuery.paddingOf(context).top;
    final bottomInset = ime > 0 ? ime : safe; // single source

    // Debug log for Samsung verification
    debugPrint(
      '[Insets] IME=$ime SAFE=$safe TOP=$topSafe bottomInset=$bottomInset',
    );

    final keyboardVisible = ime > 0;
    final contentBottomPadding = keyboardVisible ? 0.0 : safe;

    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: Colors.white,
      bottomNavigationBar: const MiniPlayerHost(),
      body: SafeArea(
        bottom: false,
        child: AnimatedPadding(
          duration: kThemeAnimationDuration,
          curve: Curves.easeOut,
          padding: EdgeInsets.only(bottom: contentBottomPadding),
          child: RefreshIndicator(
            onRefresh: () => _refreshAll(forceRefresh: true),
            displacement: 72,
            child: CustomScrollView(
              controller: _scroll,
              physics: const AlwaysScrollableScrollPhysics(),
              keyboardDismissBehavior:
                  ScrollViewKeyboardDismissBehavior.onDrag,
              slivers: [
                SliverAppBar(
                  pinned: true,
                  elevation: 0,
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black87,
                  automaticallyImplyLeading: false,
                  titleSpacing: 16,
                  centerTitle: false,
                  title: const Text(
                    'YT AudioBox',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22),
                  ),
                  actions: [
                    IconButton(
                      tooltip: 'Downloads',
                      icon: const Icon(Icons.download),
                      onPressed: _openDownloads,
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: _SearchBarContainer(
                            onChannelSelected: _onChannelSelected,
                            onManualAdd: _addChannel,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (!_isOnline)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: _buildOfflineBanner(),
                    ),
                  ),
                ..._buildSavedVideosSlivers(),
                if (_channels.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'No channels added yet.',
                            style: TextStyle(
                              fontSize: 16,
                              color: Colors.grey[600],
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  SliverList.separated(
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemCount: _channels.length,
                    itemBuilder: (context, i) {
                      final channel = _channels[i];
                      final state = _channelStates[channel.id] ??
                          const _ChannelSectionState(isLoadingInitial: true);
                      final videos = state.videos;
                      final isInitialLoading =
                          state.isLoadingInitial && videos.isEmpty;
                      final hasVideos = videos.isNotEmpty;
                      final error = state.lastError;
                      final bool inlineBusy =
                          state.isRefreshing || _isRefreshingAll;
                      final message = _describeChannelMessage(state, error);

                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Card(
                          elevation: 3,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          margin: EdgeInsets.zero,
                          child: ExpansionTile(
                            tilePadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            childrenPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 8,
                            ),
                            title: Row(
                              children: [
                                CircleAvatar(
                                  backgroundImage: channel.thumbnailUrl.isNotEmpty
                                      ? NetworkImage(channel.thumbnailUrl)
                                      : null,
                                  backgroundColor: Colors.red[100],
                                  radius: 20,
                                  child: channel.thumbnailUrl.isEmpty
                                      ? Icon(Icons.person,
                                          color: Colors.red[700])
                                      : null,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    channel.name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 18,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.refresh),
                                  tooltip: 'Refresh',
                                  onPressed: inlineBusy
                                      ? null
                                      : () => _refreshChannel(
                                            channel.id,
                                            forceRefresh: true,
                                          ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline),
                                  tooltip: 'Remove Channel',
                                  onPressed: () async {
                                    final confirm = await showDialog<bool>(
                                      context: context,
                                      builder: (context) => AlertDialog(
                                        title: const Text('Remove Channel'),
                                        content: const Text(
                                          'Are you sure you want to remove this channel?',
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.of(context).pop(
                                                  false,
                                                ),
                                            child: const Text('Cancel'),
                                          ),
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.of(context).pop(
                                                  true,
                                                ),
                                            child: const Text('Yes'),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (confirm == true) {
                                      await DatabaseService.instance
                                          .deleteChannel(channel.id);
                                      setState(() {
                                        _channelStates.remove(channel.id);
                                      });
                                      await _loadChannels();
                                      if (!mounted) return;
                                      showGlobalSnackBar(
                                        SnackBar(
                                          content: Text(
                                            'Channel removed: ${channel.name}',
                                          ),
                                        ),
                                      );
                                    }
                                  },
                                ),
                              ],
                            ),
                            children: [
                              if (isInitialLoading)
                                const Padding(
                                  padding: EdgeInsets.all(16),
                                  child: Center(
                                    child: CircularProgressIndicator(),
                                  ),
                                )
                              else if (!hasVideos)
                                Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        message,
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          color: Colors.grey[700],
                                        ),
                                      ),
                                      if (error != null || state.isStale)
                                        const SizedBox(height: 12),
                                      if (error != null || state.isStale)
                                        _buildInlineActionButton(
                                          label: 'Retry',
                                          isBusy: inlineBusy,
                                          onPressed: () => _refreshChannel(
                                            channel.id,
                                            forceRefresh: true,
                                          ),
                                        ),
                                    ],
                                  ),
                                )
                              else ...[
                                if (state.isRefreshing)
                                  const Padding(
                                    padding:
                                        EdgeInsets.symmetric(vertical: 8),
                                    child: Center(
                                      child: SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      ),
                                    ),
                                  ),
                                if (state.isStale || error != null)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 8,
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          error?.isOffline ?? false
                                              ? Icons.wifi_off
                                              : Icons.info_outline,
                                          color: Colors.orange.shade700,
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            message,
                                            style: TextStyle(
                                              color: Colors.orange.shade700,
                                            ),
                                          ),
                                        ),
                                        TextButton(
                                          onPressed: inlineBusy
                                              ? null
                                              : () => _refreshChannel(
                                                    channel.id,
                                                    forceRefresh: true,
                                                  ),
                                          child: inlineBusy
                                              ? const SizedBox(
                                                  width: 16,
                                                  height: 16,
                                                  child:
                                                      CircularProgressIndicator(
                                                    strokeWidth: 2,
                                                  ),
                                                )
                                              : const Text('Retry'),
                                        ),
                                      ],
                                    ),
                                  ),
                                ListView.separated(
                                  shrinkWrap: true,
                                  physics:
                                      const NeverScrollableScrollPhysics(),
                                  separatorBuilder: (_, __) => Divider(
                                    height: 1,
                                    color: Colors.grey[200],
                                  ),
                                  itemCount: videos.length,
                                  itemBuilder: (context, j) {
                                    final video = videos[j];
                                    return ChannelVideoTile(
                                      key: ValueKey(video.id),
                                      video: video,
                                    );
                                  },
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                const SliverToBoxAdapter(child: SizedBox(height: 16)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChannelSectionState {
  const _ChannelSectionState({
    this.videos = const [],
    this.isLoadingInitial = false,
    this.isRefreshing = false,
    this.isStale = false,
    this.lastError,
  });

  final List<Video> videos;
  final bool isLoadingInitial;
  final bool isRefreshing;
  final bool isStale;
  final FetchException? lastError;

  _ChannelSectionState copyWith({
    List<Video>? videos,
    bool? isLoadingInitial,
    bool? isRefreshing,
    bool? isStale,
    FetchException? lastError,
    bool clearError = false,
  }) {
    return _ChannelSectionState(
      videos: videos ?? this.videos,
      isLoadingInitial: isLoadingInitial ?? this.isLoadingInitial,
      isRefreshing: isRefreshing ?? this.isRefreshing,
      isStale: isStale ?? this.isStale,
      lastError: clearError ? null : lastError ?? this.lastError,
    );
  }
}

class _SearchBarContainer extends StatelessWidget {
  const _SearchBarContainer({
    required this.onChannelSelected,
    required this.onManualAdd,
  });

  final Function(Channel) onChannelSelected;
  final Function(String) onManualAdd;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 64),
      child: SizedBox(
        width: double.infinity,
        child: Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          elevation: 0,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: ChannelSearchField(
              onChannelSelected: onChannelSelected,
              onManualAdd: onManualAdd,
            ),
          ),
        ),
      ),
    );
  }
}

class SavedVideoTile extends StatefulWidget {
  const SavedVideoTile({super.key, required this.savedVideo});

  final SavedVideo savedVideo;

  @override
  State<SavedVideoTile> createState() => _SavedVideoTileState();
}

class _SavedVideoTileState extends State<SavedVideoTile> {
  bool _isStreaming = false;
  bool _isDownloading = false;
  bool _isRemoving = false;
  late final VoidCallback _playingListener;

  @override
  void initState() {
    super.initState();
    _playingListener = _handlePlayingUpdate;
    DownloadService.globalPlayingNotifier.addListener(_playingListener);
  }

  @override
  void dispose() {
    DownloadService.globalPlayingNotifier.removeListener(_playingListener);
    super.dispose();
  }

  void _handlePlayingUpdate() {
    final playing = DownloadService.globalPlayingNotifier.value;
    if (!mounted) return;
    if (playing?.videoId != widget.savedVideo.videoId) {
      return;
    }
    setState(() {
      _isStreaming = false;
    });
  }

  Video get _video => Video(
        id: widget.savedVideo.videoId,
        title: widget.savedVideo.title,
        published: widget.savedVideo.publishedAt?.toUtc() ?? DateTime.now().toUtc(),
        thumbnailUrl: widget.savedVideo.thumbnailUrl,
        channelName: widget.savedVideo.channelTitle,
        channelId: widget.savedVideo.channelId,
        duration: widget.savedVideo.duration,
      );

  bool get _isDownloaded => widget.savedVideo.status == 'downloaded';
  bool get _isDownloadingStatus => widget.savedVideo.status == 'downloading';
  bool get _hasError => widget.savedVideo.status == 'error';

  @override
  Widget build(BuildContext context) {
    final saved = widget.savedVideo;
    final durationText = _formatDuration(saved.duration);

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildThumbnail(saved.thumbnailUrl, saved.duration),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        saved.title,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        saved.channelTitle,
                        style: const TextStyle(
                          fontSize: 13,
                          color: Colors.grey,
                        ),
                      ),
                      if (durationText != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            durationText,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.grey,
                            ),
                          ),
                        ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          _buildStatusChip(
                            context,
                            _statusLabel(saved.status),
                            saved.status,
                          ),
                          if (_hasError)
                            const Text(
                              'Tap download to try again',
                              style: TextStyle(fontSize: 12, color: Colors.red),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _buildRemoveButton(),
              ],
            ),
            if (_isDownloadingStatus)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: _buildProgressBar(),
              ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _handlePlay,
                    icon: _isStreaming
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.play_arrow),
                    label: const Text('Play'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: (_isDownloadingStatus || _isDownloading)
                        ? null
                        : () async {
                            if (_isDownloadingStatus) return;
                            setState(() => _isDownloading = true);
                            try {
                              await downloadVideo(
                                context,
                                _video,
                                trackSavedVideo: true,
                              );
                            } finally {
                              if (mounted) {
                                setState(() => _isDownloading = false);
                              }
                            }
                          },
                    icon: (_isDownloading || _isDownloadingStatus)
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.download),
                    label: Text(_isDownloaded ? 'Re-download' : 'Download'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handlePlay() async {
    final localPath = await DownloadService.getDownloadedFilePath(
      widget.savedVideo.videoId,
    );
    if (localPath == null) {
      final current = DownloadService.globalPlayingNotifier.value;
      final shouldShowSpinner =
          !(current?.videoId == widget.savedVideo.videoId &&
              !(current?.isLocal ?? true));
      if (shouldShowSpinner && mounted) {
        setState(() => _isStreaming = true);
      }
      await playVideo(context, _video);
      if (!mounted) return;
      if (shouldShowSpinner) {
        setState(() => _isStreaming = false);
      }
      return;
    }

    await playVideo(context, _video);
  }

  Widget _buildRemoveButton() {
    if (_isRemoving) {
      return const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return IconButton(
      tooltip: 'Remove saved video',
      onPressed: _removeSavedVideo,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minHeight: 32, minWidth: 32),
      icon: const Icon(Icons.close),
    );
  }

  Future<void> _removeSavedVideo() async {
    if (_isRemoving) return;
    setState(() => _isRemoving = true);
    try {
      if (_isDownloadingStatus) {
        await DownloadService.cancelDownload(widget.savedVideo.videoId);
      }
      await VideoRepository.instance.removeSavedVideo(widget.savedVideo.videoId);
      showGlobalSnackBarMessage('Removed saved video');
    } catch (e) {
      showGlobalSnackBar(
        SnackBar(content: Text('Failed to remove video: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _isRemoving = false);
      }
    }
  }

  Widget _buildThumbnail(String url, Duration? duration) {
    final durationText = duration != null ? _formatDuration(duration) : null;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 120,
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (url.isNotEmpty)
                Image.network(
                  url,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    color: Colors.grey[300],
                    child: const Icon(Icons.videocam, color: Colors.grey),
                  ),
                )
              else
                Container(
                  color: Colors.grey[300],
                  child: const Icon(Icons.videocam, color: Colors.grey),
                ),
              if (durationText != null)
                Positioned(
                  right: 4,
                  bottom: 4,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      durationText,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProgressBar() {
    final total = widget.savedVideo.bytesTotal;
    final downloaded = widget.savedVideo.bytesDownloaded ?? 0;
    final progress = (total != null && total > 0)
        ? (downloaded / total).clamp(0.0, 1.0)
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(value: progress),
        const SizedBox(height: 4),
        Text(
          total != null
              ? '${_formatBytes(downloaded)} / ${_formatBytes(total)}'
              : 'Preparing download...',
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ],
    );
  }

  Widget _buildStatusChip(BuildContext context, String label, String status) {
    Color background;
    Color foreground;
    switch (status) {
      case 'downloaded':
        background = Colors.green.shade50;
        foreground = Colors.green.shade700;
        break;
      case 'downloading':
        background = Colors.blue.shade50;
        foreground = Colors.blue.shade700;
        break;
      case 'error':
        background = Colors.red.shade50;
        foreground = Colors.red.shade700;
        break;
      default:
        background = Colors.grey.shade200;
        foreground = Colors.grey.shade700;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: foreground,
        ),
      ),
    );
  }

  String? _formatDuration(Duration? duration) {
    if (duration == null) return null;
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    final mm = minutes.toString().padLeft(hours > 0 ? 2 : 1, '0');
    final ss = seconds.toString().padLeft(2, '0');
    if (hours > 0) {
      return '$hours:$mm:$ss';
    }
    return '$mm:$ss';
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'downloaded':
        return 'Downloaded';
      case 'downloading':
        return 'Downloading';
      case 'error':
        return 'Error';
      default:
        return 'Saved';
    }
  }

  String _formatBytes(int value) {
    const units = ['B', 'KB', 'MB', 'GB'];
    double size = value.toDouble();
    int unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    return '${size.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DatabaseService.instance.db;
}

Future<void> addDownloadedVideo(DownloadedVideo video) async {
  final dbClient = await DatabaseService.instance.db;
  await dbClient.insert(
    'downloaded_videos',
    video.toMap(),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
}

Future<DownloadedVideo?> getDownloadedVideo(String videoId) async {
  final dbClient = await DatabaseService.instance.db;
  final maps = await dbClient.query(
    'downloaded_videos',
    where: 'videoId = ?',
    whereArgs: [videoId],
  );
  if (maps.isNotEmpty) {
    return DownloadedVideo.fromMap(maps.first);
  }
  return null;
}
