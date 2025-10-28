import 'package:flutter/material.dart';
import '../models/channel.dart';
import '../models/video.dart';
import '../models/downloaded_video.dart';
import '../services/youtube_service.dart';
import '../services/database_service.dart';
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
  List<Channel> _channels = [];
  Map<String, List<Video>> _channelVideos = {};
  Map<String, bool> _loadingVideos = {};
  late AnimationController _logoController;
  final _scroll = ScrollController();

  void _openDownloads() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => DownloadManagerScreen()),
    );
  }

  @override
  void initState() {
    super.initState();
    _loadChannels();

    // Animation setup
    _logoController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 900),
    );
  }

  @override
  void dispose() {
    _logoController.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadChannels() async {
    _channels = await DatabaseService.instance.getChannels();
    setState(() {});
    // Fetch videos for all channels
    for (final channel in _channels) {
      _fetchAndSetVideos(channel.id);
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
      await _fetchAndSetVideos(channelId);
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
    await _fetchAndSetVideos(channel.id);
    if (!mounted) return;
    showGlobalSnackBar(
      SnackBar(content: Text('Channel added: ${channel.name}')),
    );
  }

  Future<void> _fetchAndSetVideos(String channelId) async {
    if (!mounted) return;
    setState(() {
      _loadingVideos[channelId] = true;
    });
    try {
      final videos = await YouTubeService.fetchChannelVideos(channelId);
      if (!mounted) return;
      setState(() {
        _channelVideos[channelId] = videos;
        _loadingVideos[channelId] = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _channelVideos[channelId] = [];
        _loadingVideos[channelId] = false;
      });
    }
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
          child: CustomScrollView(
            controller: _scroll,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
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
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: _SearchBarContainer(
                    onChannelSelected: _onChannelSelected,
                    onManualAdd: _addChannel,
                  ),
                ),
              ),
              if (_channels.isEmpty)
                SliverToBoxAdapter(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32.0),
                      child: Text(
                        'No channels added yet.',
                        style: TextStyle(fontSize: 16, color: Colors.grey[600]),
                      ),
                    ),
                  ),
                )
              else
                SliverList.separated(
                  separatorBuilder: (_, __) => SizedBox(height: 12),
                  itemCount: _channels.length,
                  itemBuilder: (context, i) {
                    final channel = _channels[i];
                    final videos = _channelVideos[channel.id] ?? [];
                    final isLoading = _loadingVideos[channel.id] ?? false;
                    return Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Card(
                        elevation: 3,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        margin: EdgeInsets.zero,
                        child: ExpansionTile(
                          tilePadding: EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          childrenPadding: EdgeInsets.symmetric(
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
                                    ? Icon(Icons.person, color: Colors.red[700])
                                    : null,
                              ),
                              SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  channel.name,
                                  style: TextStyle(
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
                                icon: Icon(Icons.delete_outline),
                                tooltip: 'Remove Channel',
                                onPressed: () async {
                                  final confirm = await showDialog<bool>(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                      title: Text('Remove Channel'),
                                      content: Text(
                                        'Are you sure you want to remove this channel?',
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.of(context).pop(false),
                                          child: Text('Cancel'),
                                        ),
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.of(context).pop(true),
                                          child: Text('Yes'),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (confirm == true) {
                                    await DatabaseService.instance
                                        .deleteChannel(channel.id);
                                    setState(() {
                                      _channelVideos.remove(channel.id);
                                    });
                                    _loadChannels();
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
                            if (isLoading)
                              Padding(
                                padding: EdgeInsets.all(16),
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              )
                            else if (videos.isEmpty)
                              Padding(
                                padding: EdgeInsets.all(16),
                                child: Text(
                                  'No videos found.',
                                  style: TextStyle(color: Colors.grey[600]),
                                ),
                              )
                            else
                              ListView.separated(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                separatorBuilder: (_, __) =>
                                    Divider(height: 1, color: Colors.grey[200]),
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
    );
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
