import 'dart:io' show FileSystemException;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';
import '../core/fetch_exception.dart';
import '../models/channel.dart';
import '../models/video.dart';
import '../models/saved_video.dart';
import '../models/downloaded_video.dart';
import '../repositories/video_repository.dart';
import '../services/database_service.dart';
import '../services/download_service.dart';
import '../repositories/channel_uploads_cache_repository.dart';
import '../utils/youtube_utils.dart';
import '../widgets/channel_search_field.dart';
import '../widgets/mini_player.dart';
import '../widgets/channel_video_tile.dart';
import '../core/snackbar_bus.dart';
import 'download_manager_screen.dart';
import 'add_item_screen.dart';
import '../theme/theme_notifier.dart';
import '../models/channel_upload_cache_entry.dart';
import '../settings/app_settings.dart';
import 'package:just_audio/just_audio.dart';
import 'package:sqflite/sqflite.dart';
import 'dart:async';
import '../utils/launch_utils.dart';

class ChannelManagementScreen extends StatefulWidget {
  const ChannelManagementScreen({super.key});
  @override
  State<ChannelManagementScreen> createState() =>
      _ChannelManagementScreenState();
}

class _ChannelManagementScreenState extends State<ChannelManagementScreen>
    with SingleTickerProviderStateMixin {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final ChannelUploadsCacheRepository _uploadsRepo =
      ChannelUploadsCacheRepository.instance;
  final Map<String, _ChannelUploadsState> _uploadsStates = {};
  final Map<String, Future<void>> _channelRefreshes = {};
  List<Channel> _channels = [];
  List<SavedVideo> _savedVideos = [];
  bool _isRefreshingAll = false;
  bool _isOnline = true;
  late AnimationController _logoController;
  final _scroll = ScrollController();
  StreamSubscription<dynamic>? _connectivitySub;
  StreamSubscription<List<SavedVideo>>? _savedVideosSub;

  Drawer _buildDrawer(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final notifier = context.watch<ThemeNotifier>();
    final appSettings = context.watch<AppSettingsNotifier>();
    return Drawer(
      child: Container(
        color: theme.drawerTheme.backgroundColor ?? colorScheme.surface,
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            DrawerHeader(
              decoration: BoxDecoration(color: colorScheme.primary),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    'YT AudioBox',
                    style:
                        theme.textTheme.headlineSmall?.copyWith(
                          color: colorScheme.onPrimary,
                          fontWeight: FontWeight.bold,
                        ) ??
                        TextStyle(
                          color: colorScheme.onPrimary,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Audio downloader & player',
                    style:
                        theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onPrimary.withOpacity(0.85),
                        ) ??
                        TextStyle(
                          color: colorScheme.onPrimary.withOpacity(0.85),
                        ),
                  ),
                ],
              ),
            ),
            SwitchListTile.adaptive(
              secondary: Icon(
                notifier.isDarkMode ? Icons.nightlight_round : Icons.wb_sunny,
              ),
              title: const Text('Dark Mode'),
              value: notifier.isDarkMode,
              onChanged: (value) => notifier.toggleTheme(value),
            ),
            SwitchListTile.adaptive(
              secondary: const Icon(Icons.search_off),
              title: const Text('Enable API search'),
              subtitle: const Text('Uses YouTube Data API quota'),
              value: appSettings.enableApiSearch,
              onChanged: (value) => appSettings.setEnableApiSearch(value),
            ),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('Add channel or video'),
              onTap: () {
                Navigator.pop(context);
                _openAddScreen();
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.email_outlined),
              title: const Text('Contact / Support'),
              subtitle: const Text(kSupportEmail),
              onTap: () => openSupportEmail(context),
              onLongPress: () => copySupportEmail(context),
              trailing: IconButton(
                icon: const Icon(Icons.copy),
                tooltip: 'Copy email',
                onPressed: () => copySupportEmail(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openDownloads() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => DownloadManagerScreen()),
    );
  }

  Future<void> _openAddScreen() async {
    final added = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (context) => const AddItemScreen()),
    );
    if (added == true) {
      await _loadChannels();
    }
  }

  Future<void> _initConnectivity() async {
    final connectivity = Connectivity();
    final initial = await connectivity.checkConnectivity();
    _updateConnectivityStatus(_isConnected(initial), silent: true);
    _connectivitySub = connectivity.onConnectivityChanged.listen(
      (event) => _updateConnectivityStatus(_isConnected(event)),
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
    _savedVideosSub = VideoRepository.instance.watchSavedVideos().listen((
      videos,
    ) {
      if (!mounted) return;
      setState(() {
        _savedVideos = videos;
      });
      DownloadService.prefetchStreamsForSavedVideos(videos);
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
      final ids = channels.map((c) => c.id).toSet();
      _uploadsStates.removeWhere((key, _) => !ids.contains(key));
    });
  }

  Future<void> _addChannel(String urlOrId) async {
    try {
      final resolved = await resolveChannelFromInput(urlOrId);
      final existing =
          await DatabaseService.instance.getChannelById(resolved.id);
      if (existing != null) {
        // Optionally backfill thumbnail/name if missing.
        if ((existing.thumbnailUrl.isEmpty && resolved.thumbnailUrl != null) ||
            (existing.name.isEmpty && resolved.name.isNotEmpty)) {
          await DatabaseService.instance.updateChannel(
            Channel(
              id: existing.id,
              name: resolved.name.isNotEmpty ? resolved.name : existing.name,
              description: existing.description,
              thumbnailUrl:
                  resolved.thumbnailUrl ?? existing.thumbnailUrl,
              lastVideoId: existing.lastVideoId,
              handle: existing.handle,
              subscriberCount: existing.subscriberCount,
              hiddenSubscriberCount: existing.hiddenSubscriberCount,
            ),
          );
        }
        if (!mounted) return;
        showGlobalSnackBar(
          SnackBar(
            content: Text(
              '${existing.name.isNotEmpty ? existing.name : resolved.name} is already in your library.',
            ),
          ),
        );
        return;
      }
      await DatabaseService.instance.addChannel(
        Channel(
          id: resolved.id,
          name: resolved.name,
          thumbnailUrl: resolved.thumbnailUrl ?? '',
          lastVideoId:
              '', // Set empty lastVideoId so background task processes all videos initially
        ),
      );
      await _loadChannels();
      await _refreshChannelUploads(resolved.id, force: true);
      if (!mounted) return;
      showGlobalSnackBar(
        SnackBar(content: Text('Channel added: ${resolved.name}')),
      );
    } catch (e) {
      if (!mounted) return;
      showGlobalSnackBar(SnackBar(content: Text('Failed to add channel: $e')));
    }
  }

  void _onChannelSelected(Channel channel) async {
    await _loadChannels();
    await _refreshChannelUploads(channel.id, force: true);
    if (!mounted) return;
    showGlobalSnackBar(
      SnackBar(content: Text('Channel added: ${channel.name}')),
    );
  }

  _ChannelUploadsState _getUploadsState(String channelId) =>
      _uploadsStates[channelId] ?? const _ChannelUploadsState();

  void _setUploadsState(String channelId, _ChannelUploadsState state) {
    if (!mounted) return;
    setState(() {
      _uploadsStates[channelId] = state;
    });
  }

  Future<void> _loadCachedUploads(String channelId) async {
    final existing = _getUploadsState(channelId);
    if (existing.uploads.isEmpty && !existing.isLoading) {
      _setUploadsState(
        channelId,
        existing.copyWith(isLoading: true, errorMessage: null),
      );
    }

    try {
      final cached = await _uploadsRepo.getCachedUploads(channelId);
      final meta = await _uploadsRepo.getCacheMeta(channelId);
      if (!mounted) return;
      final isStale = _uploadsRepo.isStale(meta?.lastFetchedAt);
      _setUploadsState(
        channelId,
        _getUploadsState(channelId).copyWith(
              uploads: cached,
              isLoading: false,
              isStale: isStale,
              lastFetchedAt: meta?.lastFetchedAt,
              errorMessage: null,
            ),
      );
      if (isStale) {
        await _refreshChannelUploads(channelId, force: false);
      }
    } catch (_) {
      if (!mounted) return;
      _setUploadsState(
        channelId,
        _getUploadsState(channelId).copyWith(
              isLoading: false,
              isRefreshing: false,
              errorMessage: 'Failed to load cached uploads.',
            ),
      );
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
          (channel) =>
              _refreshChannelUploads(channel.id, force: forceRefresh),
        ),
      );
    } finally {
      if (!mounted) return;
      setState(() {
        _isRefreshingAll = false;
      });
    }
  }

  Future<void> _refreshChannelUploads(
    String channelId, {
    bool force = false,
  }) {
    final inFlight = _channelRefreshes[channelId];
    if (inFlight != null) return inFlight;

    final future = () async {
      final current = _getUploadsState(channelId);
      _setUploadsState(
        channelId,
        current.copyWith(
          isRefreshing: true,
          isLoading: current.uploads.isEmpty,
          errorMessage: null,
        ),
      );

      try {
        final refreshed = await _uploadsRepo.refreshFromRss(
          channelId,
          forceRefresh: force,
        );
        if (!mounted) return;
        _setUploadsState(
          channelId,
          _getUploadsState(channelId).copyWith(
                uploads: refreshed,
                isLoading: false,
                isRefreshing: false,
                isStale: false,
                lastFetchedAt: DateTime.now().toUtc(),
                errorMessage: null,
              ),
        );
      } on FetchException catch (e) {
        if (!mounted) return;
        _setUploadsState(
          channelId,
          _getUploadsState(channelId).copyWith(
                isLoading: false,
                isRefreshing: false,
                isStale: true,
                errorMessage: e.message,
              ),
        );
      } catch (_) {
        if (!mounted) return;
        _setUploadsState(
          channelId,
          _getUploadsState(channelId).copyWith(
                isLoading: false,
                isRefreshing: false,
                isStale: true,
                errorMessage: 'Unable to refresh this channel right now.',
              ),
        );
      }
    }();

    _channelRefreshes[channelId] = future;
    return future.whenComplete(() {
      _channelRefreshes.remove(channelId);
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
            'Saved Audios',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
        ),
      ),
      SliverList(
        delegate: SliverChildBuilderDelegate((context, index) {
          final saved = _savedVideos[index];
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: SavedVideoTile(savedVideo: saved),
          );
        }, childCount: _savedVideos.length),
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

  Widget _buildChannelCard(Channel channel) {
    final uploadsState = _getUploadsState(channel.id);
    final bool isInitialLoading =
        uploadsState.isLoading && uploadsState.uploads.isEmpty;
    final bool hasVideos = uploadsState.uploads.isNotEmpty;
    final bool inlineBusy =
        uploadsState.isRefreshing || _isRefreshingAll;
    final errorMessage = uploadsState.errorMessage;
    final bool isStale = uploadsState.isStale;

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
          onExpansionChanged: (open) {
            if (open) {
              _loadCachedUploads(channel.id);
            }
          },
          title: Row(
            children: [
              CircleAvatar(
                backgroundImage:
                    channel.thumbnailUrl.isNotEmpty
                        ? NetworkImage(channel.thumbnailUrl)
                        : null,
                backgroundColor: Colors.red[100],
                radius: 20,
                child: channel.thumbnailUrl.isEmpty
                    ? Icon(
                        Icons.person,
                        color: Colors.red[700],
                      )
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
              if (isStale)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(
                    Icons.update,
                    size: 18,
                    color: Colors.orange.shade700,
                  ),
                ),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh',
                onPressed: inlineBusy
                    ? null
                    : () => _refreshChannelUploads(
                          channel.id,
                          force: true,
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
                          onPressed: () => Navigator.of(context).pop(false),
                          child: const Text('Cancel'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(true),
                          child: const Text('Yes'),
                        ),
                      ],
                    ),
                  );
                  if (confirm == true) {
                    await DatabaseService.instance.deleteChannel(channel.id);
                    setState(() {
                      _channelRefreshes.remove(channel.id);
                      _uploadsStates.remove(channel.id);
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
                    if (errorMessage != null && errorMessage.isNotEmpty) ...[
                      Text(
                        errorMessage,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey[800],
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _isOnline
                            ? 'Tap Retry to try again.'
                            : "You're offline. Pull to refresh after reconnecting.",
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.grey[700],
                        ),
                      ),
                    ] else
                      Text(
                        'No videos available yet.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.grey[700],
                        ),
                      ),
                    const SizedBox(height: 12),
                    _buildInlineActionButton(
                      label: 'Retry',
                      isBusy: inlineBusy,
                      onPressed: inlineBusy
                          ? null
                          : () => _refreshChannelUploads(
                                channel.id,
                                force: true,
                              ),
                    ),
                  ],
                ),
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (uploadsState.isRefreshing)
                    const LinearProgressIndicator(
                      minHeight: 2,
                    )
                  else if (isStale)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.info_outline,
                            size: 18,
                            color: Colors.orange.shade700,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Showing cached uploads. Refreshing in background...',
                              style: TextStyle(
                                color: Colors.orange.shade700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    separatorBuilder: (_, __) => Divider(
                      height: 1,
                      color: Colors.grey[200],
                    ),
                    itemCount: uploadsState.uploads.length,
                    itemBuilder: (context, j) {
                      final item = uploadsState.uploads[j];
                      final video = _mapUploadToVideo(
                        item,
                        channel,
                      );
                      return ChannelVideoTile(
                        key: ValueKey(item.videoId),
                        video: video,
                      );
                    },
                  ),
                  if (errorMessage != null && errorMessage.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.info_outline,
                            color: Colors.orange.shade700,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Last refresh failed. Showing cached uploads.',
                              style: TextStyle(
                                color: Colors.orange.shade700,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: inlineBusy
                                ? null
                                : () => _refreshChannelUploads(
                                      channel.id,
                                      force: true,
                                    ),
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 4),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Video _mapUploadToVideo(
    ChannelUploadCacheEntry entry,
    Channel channel,
  ) {
    final thumb = entry.thumbnailUrl.isNotEmpty
        ? entry.thumbnailUrl
        : 'https://i.ytimg.com/vi/${entry.videoId}/hqdefault.jpg';
    return Video(
      id: entry.videoId,
      title: entry.title,
      published: entry.publishedAt ?? DateTime.now().toUtc(),
      thumbnailUrl: thumb,
      channelName: channel.name,
      channelId: channel.id,
    );
  }

  @override
  Widget build(BuildContext context) {
    final ime = MediaQuery.viewInsetsOf(context).bottom; // keyboard
    final safe = MediaQuery.paddingOf(context).bottom; // system nav

    final keyboardVisible = ime > 0;
    final contentBottomPadding = keyboardVisible ? 0.0 : safe;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final settings = context.watch<AppSettingsNotifier>();
    final enableApiSearch = settings.enableApiSearch;

    return Scaffold(
      key: _scaffoldKey,
      resizeToAvoidBottomInset: true,
      backgroundColor: theme.scaffoldBackgroundColor,
      bottomNavigationBar: const MiniPlayerHost(),
      drawer: _buildDrawer(context),
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
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              slivers: [
                SliverAppBar(
                  pinned: true,
                  elevation: 0,
                  backgroundColor: colorScheme.surface,
                  foregroundColor: colorScheme.onSurface,
                  titleSpacing: 16,
                  centerTitle: false,
                  leading: IconButton(
                    icon: const Icon(Icons.menu),
                    onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                    tooltip: 'Menu',
                  ),
                  title: const Text(
                    'YT AudioBox',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22),
                  ),
                  actions: [
                    IconButton(
                      tooltip: 'Add',
                      icon: const Icon(Icons.add),
                      onPressed: _openAddScreen,
                    ),
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
                          child: enableApiSearch
                              ? _SearchBarContainer(
                                  onChannelSelected: _onChannelSelected,
                                  onManualAdd: _addChannel,
                                )
                              : _ApiSearchDisabledNotice(
                                  onAdd: _openAddScreen,
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
                      return _buildChannelCard(channel);
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

class _ChannelUploadsState {
  const _ChannelUploadsState({
    this.uploads = const [],
    this.isLoading = false,
    this.isRefreshing = false,
    this.isStale = false,
    this.lastFetchedAt,
    this.errorMessage,
  });

  final List<ChannelUploadCacheEntry> uploads;
  final bool isLoading;
  final bool isRefreshing;
  final bool isStale;
  final DateTime? lastFetchedAt;
  final String? errorMessage;

  _ChannelUploadsState copyWith({
    List<ChannelUploadCacheEntry>? uploads,
    bool? isLoading,
    bool? isRefreshing,
    bool? isStale,
    DateTime? lastFetchedAt,
    String? errorMessage,
  }) {
    return _ChannelUploadsState(
      uploads: uploads ?? this.uploads,
      isLoading: isLoading ?? this.isLoading,
      isRefreshing: isRefreshing ?? this.isRefreshing,
      isStale: isStale ?? this.isStale,
      lastFetchedAt: lastFetchedAt ?? this.lastFetchedAt,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

class _ApiSearchDisabledNotice extends StatelessWidget {
  const _ApiSearchDisabledNotice({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceVariant,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.search_off),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Search disabled to save API quota.',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  'Use Add to paste a channel or video link.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurface.withOpacity(0.7),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton(
            onPressed: onAdd,
            child: const Text('Add'),
          ),
        ],
      ),
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
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 64),
      child: SizedBox(
        width: double.infinity,
        child: Material(
          color: theme.colorScheme.surface,
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
  bool _hasLocalFile = false;
  bool _checkedLocalFile = false;
  late final VoidCallback _playingListener;

  @override
  void initState() {
    super.initState();
    _playingListener = _handlePlayingUpdate;
    DownloadService.globalPlayingNotifier.addListener(_playingListener);
    _refreshLocalFileAvailability();
  }

  @override
  void dispose() {
    DownloadService.globalPlayingNotifier.removeListener(_playingListener);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant SavedVideoTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.savedVideo.videoId != widget.savedVideo.videoId ||
        oldWidget.savedVideo.status != widget.savedVideo.status) {
      _refreshLocalFileAvailability();
    }
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

  Future<void> _refreshLocalFileAvailability() async {
    _checkedLocalFile = false;
    final path = await DownloadService.getDownloadedFilePath(
      widget.savedVideo.videoId,
    );
    if (!mounted) return;
    setState(() {
      _checkedLocalFile = true;
      _hasLocalFile = path != null;
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
  bool get _showDownloadButton =>
      !_isDownloaded || !_checkedLocalFile || !_hasLocalFile;

  @override
  Widget build(BuildContext context) {
    final saved = widget.savedVideo;
    final durationText = _formatDuration(saved.duration);
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final muted = onSurface.withOpacity(0.7);

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
                        style:
                            theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: onSurface,
                            ) ??
                            TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: onSurface,
                            ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        saved.channelTitle,
                        style:
                            theme.textTheme.bodyMedium?.copyWith(
                              color: muted,
                            ) ??
                            TextStyle(fontSize: 13, color: muted),
                      ),
                      if (durationText != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            durationText,
                            style:
                                theme.textTheme.bodySmall?.copyWith(
                                  color: muted,
                                ) ??
                                TextStyle(fontSize: 12, color: muted),
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
                            Text(
                              'Tap download to try again',
                              style:
                                  theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.error,
                                  ) ??
                                  TextStyle(
                                    fontSize: 12,
                                    color: theme.colorScheme.error,
                                  ),
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
                  child: ValueListenableBuilder<PlayingAudio?>(
                    valueListenable: DownloadService.globalPlayingNotifier,
                    builder: (context, playing, _) {
                      final isSameVideo =
                          playing?.videoId == widget.savedVideo.videoId;
                      return StreamBuilder<PlayerState>(
                        stream:
                            DownloadService.globalAudioPlayer.playerStateStream,
                        builder: (context, snapshot) {
                          final playerState = snapshot.data;
                          final processingState =
                              playerState?.processingState ??
                              ProcessingState.idle;
                          final isBuffering =
                              isSameVideo &&
                              (processingState == ProcessingState.loading ||
                                  processingState == ProcessingState.buffering);
                          bool isPlaying = false;
                          if (isSameVideo) {
                            if (playerState == null) {
                              isPlaying = playing?.isPlaying ?? false;
                            } else {
                              isPlaying =
                                  playerState.playing &&
                                  processingState !=
                                      ProcessingState.completed &&
                                  processingState != ProcessingState.idle;
                            }
                          }
                          final isLoading = _isStreaming || isBuffering;
                          final isPlayableOffline =
                              _isDownloaded && _hasLocalFile;
                          final label = isLoading
                              ? 'Loading...'
                              : isPlaying
                              ? 'Pause'
                              : (isSameVideo && isPlayableOffline)
                              ? 'Resume'
                              : isPlayableOffline
                              ? 'Play Offline'
                              : 'Play';

                          final icon = isLoading
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : Icon(
                                  isPlaying ? Icons.pause : Icons.play_arrow,
                                );

                          return ElevatedButton.icon(
                            onPressed: isLoading ? null : _handlePlay,
                            icon: icon,
                            label: Text(label),
                          );
                        },
                      );
                    },
                  ),
                ),
                const SizedBox(width: 12),
                if (_showDownloadButton)
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
                                // Refresh local availability once the download flow completes.
                                unawaited(_refreshLocalFileAvailability());
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
    final current = DownloadService.globalPlayingNotifier.value;
    final isCurrent = current?.videoId == widget.savedVideo.videoId;

    if (isCurrent) {
      try {
        await DownloadService.togglePlayback();
      } on FileSystemException {
        showGlobalSnackBarMessage(
          'Audio file not found. Stream or re-download to play.',
        );
        await DownloadService.clearPlaybackSession();
        if (mounted) {
          setState(() {
            _isStreaming = false;
          });
        }
      } catch (e) {
        showGlobalSnackBarMessage('Playback error: $e');
      }
      return;
    }

    if (mounted) {
      setState(() => _isStreaming = true);
    }
    _kickOffPlaybackFlow();
  }

  void _kickOffPlaybackFlow() {
    // Yield to the next frame so the loading spinner animates before doing any I/O.
    unawaited(
      Future<void>.delayed(Duration.zero, () async {
        await SchedulerBinding.instance.endOfFrame;
        if (!mounted) return;
        await _runPlaybackFlow();
      }),
    );
  }

  Future<void> _runPlaybackFlow() async {
    // Yield once before doing any heavy I/O so the loading spinner animates.
    await Future<void>.delayed(Duration.zero);
    bool isLocal = false;
    try {
      final localPath = await DownloadService.getDownloadedFilePath(
        widget.savedVideo.videoId,
      );
      isLocal = localPath != null;
      if (isLocal && mounted) {
        setState(() => _isStreaming = false);
      }
      await playVideo(context, _video);
    } finally {
      if (!isLocal && mounted) {
        setState(() => _isStreaming = false);
      }
    }
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
      await VideoRepository.instance.removeSavedVideo(
        widget.savedVideo.videoId,
      );
      showGlobalSnackBarMessage('Removed saved video');
    } catch (e) {
      showGlobalSnackBar(SnackBar(content: Text('Failed to remove video: $e')));
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
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.6),
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
