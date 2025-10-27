import 'package:flutter/material.dart';
import '../models/channel.dart';
import '../models/video.dart';
import '../models/downloaded_video.dart';
import '../services/youtube_service.dart';
import '../services/database_service.dart';
import '../services/download_service.dart';
import '../utils/youtube_utils.dart';
import '../widgets/channel_search_field.dart';
import '../widgets/mini_player.dart';
import '../core/snackbar_bus.dart';
import 'download_manager_screen.dart';
import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'dart:async';

class ChannelManagementScreen extends StatefulWidget {
  const ChannelManagementScreen({super.key});
  @override
  State<ChannelManagementScreen> createState() => _ChannelManagementScreenState();
}

class _ChannelManagementScreenState extends State<ChannelManagementScreen>
    with SingleTickerProviderStateMixin {
  List<Channel> _channels = [];
  Map<String, List<Video>> _channelVideos = {};
  Map<String, bool> _loadingVideos = {};
  late final VoidCallback _notifierListener;
  Map<String, bool> _downloading = {}; // Track per-video download status
  Map<String, bool> _streaming = {}; // Track streaming state
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
    _notifierListener = () {
      if (!mounted) return;
      setState(() {
        // Update any playing state if needed
      });
    };
    DownloadService.globalPlayingNotifier.addListener(_notifierListener);

    // Animation setup
    _logoController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 900),
    );
  }

  @override
  void dispose() {
    DownloadService.globalPlayingNotifier.removeListener(_notifierListener);
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
      SnackBar(content: Text('Channel selected: ${channel.name}')),
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

  Future<void> _playDownloadedVideo(Video video, String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      showGlobalSnackBar(
        SnackBar(content: Text('Audio file not found: $filePath')),
      );
      return;
    }
    await DownloadService.playOrPause(
      video.id,
      filePath,
      title: video.title,
      channelName: video.channelName,
      thumbnailUrl: video.thumbnailUrl,
    );
  }

  Future<void> _handlePlay(Video video) async {
    final filePath = await DownloadService.getDownloadedFilePath(video.id);
    if (filePath != null) {
      await _playDownloadedVideo(video, filePath);
      return;
    }
    final current = DownloadService.globalPlayingNotifier.value;
    final shouldShowSpinner =
        !(current?.videoId == video.id && !(current?.isLocal ?? true));
    if (shouldShowSpinner) {
      setState(() {
        _streaming[video.id] = true;
      });
    }
    try {
      await DownloadService.playStream(
        videoId: video.id,
        videoUrl: 'https://www.youtube.com/watch?v=${video.id}',
        title: video.title,
        channelName: video.channelName,
        thumbnailUrl: video.thumbnailUrl,
      );
    } catch (e) {
      if (!mounted) return;
      showGlobalSnackBar(
        SnackBar(content: Text('Failed to play audio: $e')),
      );
    } finally {
      if (!mounted) return;
      if (shouldShowSpinner) {
        setState(() {
          _streaming[video.id] = false;
        });
      }
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
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 22,
                  ),
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
                            style: TextStyle(
                              fontSize: 16,
                              color: Colors.grey[600],
                            ),
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
                                      content: Text('Are you sure you want to remove this channel?'),
                                            actions: [
                                              TextButton(
                                          onPressed: () => Navigator.of(context).pop(false),
                                                child: Text('Cancel'),
                                              ),
                                              TextButton(
                                          onPressed: () => Navigator.of(context).pop(true),
                                                child: Text('Yes'),
                                              ),
                                            ],
                                          ),
                                        );
                                        if (confirm == true) {
                                    await DatabaseService.instance.deleteChannel(channel.id);
                                          setState(() {
                                            _channelVideos.remove(channel.id);
                                          });
                                          _loadChannels();
                                          if (!mounted) return;
                                          showGlobalSnackBar(
                                      SnackBar(content: Text('Channel removed: ${channel.name}')),
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
                                child: Center(child: CircularProgressIndicator()),
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
                                      physics: NeverScrollableScrollPhysics(),
                                separatorBuilder: (_, __) => Divider(height: 1, color: Colors.grey[200]),
                                      itemCount: videos.length,
                                      itemBuilder: (context, j) {
                                        final video = videos[j];
                                        return Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 6.0, horizontal: 2.0),
                                          child: Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              ClipRRect(
                                          borderRadius: BorderRadius.circular(8),
                                          child: video.thumbnailUrl.isNotEmpty
                                              ? Image.network(video.thumbnailUrl, width: 80, height: 45, fit: BoxFit.cover)
                                              : Container(width: 80, height: 45, color: Colors.grey[300]),
                                              ),
                                              SizedBox(width: 10),
                                              Expanded(
                                                child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      video.title,
                                                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                                                      maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                    ),
                                                    SizedBox(height: 4),
                                                    Text(
                                                      'Published: ${video.published.toLocal().toString().split(' ')[0]}',
                                                style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                                                    ),
                                                    SizedBox(height: 6),
                                              FutureBuilder<DownloadedVideo?>(
                                                future: DatabaseService.instance.getDownloadedVideo(video.id),
                                                      builder: (context, snapshot) {
                                                  final record = snapshot.data;
                                                  final status = record?.status ?? '';
                                                  final isManualDownloading = _downloading[video.id] ?? false;
                                                  final isDownloading = status == 'downloading' || isManualDownloading;
                                                  final isDownloaded = status == 'completed';

                                                        if (isDownloading) {
                                                    return ValueListenableBuilder<Map<String, double>>(
                                                      valueListenable: DownloadService.downloadProgressNotifier,
                                                      builder: (context, progressMap, _) {
                                                        final progress = progressMap[video.id];
                                                        final normalized = progress?.clamp(0.0, 1.0);
                                                        final progressText = normalized != null && normalized > 0
                                                                      ? '${(normalized * 100).toStringAsFixed(0)}%'
                                                                      : null;

                                                                  return Row(
                                                                    children: [
                                                                      SizedBox(
                                                              height: 18,
                                                              width: 18,
                                                                        child: CircularProgressIndicator(
                                                                value: normalized != null && normalized > 0 ? normalized : null,
                                                                strokeWidth: 2,
                                                              ),
                                                            ),
                                                            SizedBox(width: 12),
                                                                      Expanded(
                                                                        child: Text(
                                                                progressText != null
                                                                              ? 'Download in progress ($progressText)'
                                                                              : 'Download in progress...',
                                                                style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
                                                                        ),
                                                                      ),
                                                                      IconButton(
                                                              icon: Icon(Icons.close, size: 20, color: Colors.red),
                                                              tooltip: 'Cancel Download',
                                                                        onPressed: () async {
                                                                final confirm = await showDialog<bool>(
                                                                                context: context,
                                                                  builder: (context) => AlertDialog(
                                                                    title: Text('Cancel Download'),
                                                                    content: Text('Are you sure you want to cancel this download?'),
                                                                                      actions: [
                                                                                        TextButton(
                                                                        onPressed: () => Navigator.of(context).pop(false),
                                                                        child: Text('No'),
                                                                                        ),
                                                                                        TextButton(
                                                                        onPressed: () => Navigator.of(context).pop(true),
                                                                        child: Text('Yes'),
                                                                                        ),
                                                                                      ],
                                                                                    ),
                                                                              );
                                                                if (confirm == true) {
                                                                  await DownloadService.cancelDownload(video.id);
                                                                  if (!mounted) return;
                                                                            setState(() {
                                                                              _downloading[video.id] = false;
                                                                            });
                                                                  showGlobalSnackBarMessage('Download cancelled');
                                                                          }
                                                                        },
                                                                      ),
                                                                    ],
                                                                  );
                                                                },
                                                          );
                                                        }

                                                  if (snapshot.connectionState == ConnectionState.waiting && !_downloading.containsKey(video.id)) {
                                                          return SizedBox(
                                                            height: 32,
                                                            child: Center(
                                                              child: SizedBox(
                                                                height: 16,
                                                                width: 16,
                                                          child: CircularProgressIndicator(strokeWidth: 2),
                                                              ),
                                                            ),
                                                          );
                                                        }

                                                  return ValueListenableBuilder<PlayingAudio?>(
                                                    valueListenable: DownloadService.globalPlayingNotifier,
                                                          builder: (context, playing, _) {
                                                      final isSameVideo = playing?.videoId == video.id;
                                                      final isThisPlaying =
                                                          isSameVideo && (playing?.isPlaying ?? false);
                                                      final isStreaming = _streaming[video.id] ?? false;
                                                      final playLabel = isStreaming
                                                          ? 'Loading...'
                                                          : isThisPlaying
                                                              ? 'Pause'
                                                              : isSameVideo
                                                                  ? 'Resume'
                                                                  : 'Play';
                                                      final playIcon = isThisPlaying
                                                          ? Icons.pause
                                                          : Icons.play_arrow;

                                                      final playButton = ElevatedButton(
                                                        style: ElevatedButton.styleFrom(
                                                          backgroundColor: Colors.green[600],
                                                          padding:
                                                              const EdgeInsets.symmetric(vertical: 10),
                                                          shape: RoundedRectangleBorder(
                                                            borderRadius: BorderRadius.circular(8),
                                                          ),
                                                        ),
                                                        onPressed: isStreaming
                                                            ? null
                                                            : () => _handlePlay(video),
                                                        child: Row(
                                                          mainAxisAlignment: MainAxisAlignment.center,
                                                          mainAxisSize: MainAxisSize.min,
                                                          children: [
                                                            if (isStreaming)
                                                              const SizedBox(
                                                                width: 16,
                                                                height: 16,
                                                                child: CircularProgressIndicator(
                                                                  strokeWidth: 2,
                                                                  color: Colors.white,
                                                                ),
                                                              )
                                                            else
                                                              Icon(
                                                                playIcon,
                                                                color: Colors.white,
                                                              ),
                                                            const SizedBox(width: 6),
                                                            Text(
                                                              playLabel,
                                                              style: const TextStyle(
                                                                color: Colors.white,
                                                                fontWeight: FontWeight.w600,
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      );

                                                      final downloadButton = ElevatedButton(
                                                        style: ElevatedButton.styleFrom(
                                                          backgroundColor: Colors.red[600],
                                                          padding:
                                                              const EdgeInsets.symmetric(vertical: 10),
                                                          shape: RoundedRectangleBorder(
                                                            borderRadius: BorderRadius.circular(8),
                                                          ),
                                                        ),
                                                        onPressed: isDownloaded
                                                            ? () => showGlobalSnackBarMessage(
                                                                  'Already downloaded.',
                                                                )
                                                            : () async {
                                                                setState(() {
                                                                  _downloading[video.id] = true;
                                                                });
                                                                if (!mounted) return;
                                                                showGlobalSnackBarMessage(
                                                                  'Download started: ${video.title}',
                                                                );
                                                                final result =
                                                                    await DownloadService.downloadAudio(
                                                                  videoId: video.id,
                                                                  videoUrl:
                                                                      'https://www.youtube.com/watch?v=${video.id}',
                                                                  title: video.title,
                                                                  channelName: video.channelName,
                                                                  thumbnailUrl: video.thumbnailUrl,
                                                                  onProgress: (_, __) {},
                                                                );
                                                                if (!mounted) return;
                                                                setState(() {
                                                                  _downloading[video.id] = false;
                                                                });
                                                                if (!mounted) return;
                                                                if (result != null) {
                                                                  showGlobalSnackBarMessage(
                                                                    'Download complete: ${video.title}',
                                                                  );
                                                                } else if (!DownloadService
                                                                    .consumeCancelledFlag(video.id)) {
                                                                  showGlobalSnackBarMessage(
                                                                    'Download failed: ${video.title}',
                                                                  );
                                                                }
                                                              },
                                                        child: Row(
                                                          mainAxisAlignment: MainAxisAlignment.center,
                                                          mainAxisSize: MainAxisSize.min,
                                                          children: [
                                                            const Icon(
                                                              Icons.download,
                                                              color: Colors.white,
                                                            ),
                                                            const SizedBox(width: 6),
                                                            Text(
                                                              isDownloaded ? 'Downloaded' : 'Download',
                                                              style: const TextStyle(
                                                                color: Colors.white,
                                                                fontWeight: FontWeight.w600,
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      );

                                                      return Padding(
                                                        padding: const EdgeInsets.symmetric(
                                                          horizontal: 8,
                                                          vertical: 4,
                                                        ),
                                                        child: LayoutBuilder(
                                                          builder: (context, innerConstraints) {
                                                            final isCompact =
                                                                innerConstraints.maxWidth < 360;
                                                            if (isCompact) {
                                                              return Column(
                                                                crossAxisAlignment:
                                                                    CrossAxisAlignment.stretch,
                                                                children: [
                                                                  playButton,
                                                                  const SizedBox(height: 8),
                                                                  downloadButton,
                                                                ],
                                                              );
                                                            }
                                                            return Row(
                                                              children: [
                                                                Expanded(child: playButton),
                                                                const SizedBox(width: 8),
                                                                Expanded(child: downloadButton),
                                                              ],
                                                            );
                                                          },
                                                        ),
                                                      );
                                                          },
                                                        );
                                                     },
                                                   ),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
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
