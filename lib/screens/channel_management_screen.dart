import 'package:flutter/material.dart';
import '../models/channel.dart';
import '../models/video.dart';
import '../models/downloaded_video.dart';
import '../services/youtube_service.dart';
import '../services/database_service.dart';
import '../services/download_service.dart';
import '../services/notification_service.dart';
import '../utils/youtube_utils.dart';
import '../widgets/channel_search_field.dart';
import '../widgets/mini_player.dart';
import '../widgets/audio_player_bottom_sheet.dart';
import 'download_manager_screen.dart';
import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';

class ChannelManagementScreen extends StatefulWidget {
  @override
  _ChannelManagementScreenState createState() => _ChannelManagementScreenState();
}

class _ChannelManagementScreenState extends State<ChannelManagementScreen> with SingleTickerProviderStateMixin {
  List<Channel> _channels = [];
  Map<String, List<Video>> _channelVideos = {};
  Map<String, bool> _loadingVideos = {};
  String? _currentlyPlayingId;
  bool _isPlaying = false;
  late final VoidCallback _notifierListener;
  Map<String, bool> _downloading = {}; // Track per-video download status
  Map<String, double> _downloadProgress = {}; // Track per-video download progress (0.0 - 1.0)
  late AnimationController _logoController;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _fadeAnimation;
  bool _showLogo = true;

  @override
  void initState() {
    super.initState();
    _loadChannels();
    _notifierListener = () {
      if (!mounted) return;
      final playing = DownloadService.globalPlayingNotifier.value;
      setState(() {
        _currentlyPlayingId = playing?.videoId;
        _isPlaying = playing?.isPlaying ?? false;
      });
    };
    DownloadService.globalPlayingNotifier.addListener(_notifierListener);

    // Animation setup
    _logoController = AnimationController(vsync: this, duration: Duration(milliseconds: 900));
    _slideAnimation = Tween<Offset>(begin: Offset(0, 0), end: Offset(0, -1.2)).animate(CurvedAnimation(parent: _logoController, curve: Curves.easeInOut));
    _fadeAnimation = Tween<double>(begin: 1.0, end: 0.0).animate(CurvedAnimation(parent: _logoController, curve: Curves.easeIn));
    // Start animation after a short delay
    Future.delayed(Duration(milliseconds: 700), () {
      if (mounted) _logoController.forward().then((_) => setState(() => _showLogo = false));
    });
  }

  @override
  void dispose() {
    DownloadService.globalPlayingNotifier.removeListener(_notifierListener);
    _logoController.dispose();
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
      await DatabaseService.instance.addChannel(Channel(
        id: channelId, 
        name: channelName,
        lastVideoId: '', // Set empty lastVideoId so background task processes all videos initially
      ));
      await _loadChannels();
      await _fetchAndSetVideos(channelId);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to add channel: $e')));
    }
  }

  void _onChannelSelected(Channel channel) async {
    await _loadChannels();
    await _fetchAndSetVideos(channel.id);
  }

  Future<void> _fetchAndSetVideos(String channelId) async {
    setState(() {
      _loadingVideos[channelId] = true;
    });
    try {
      final videos = await YouTubeService.fetchChannelVideos(channelId);
      setState(() {
        _channelVideos[channelId] = videos;
        _loadingVideos[channelId] = false;
      });
    } catch (e) {
      setState(() {
        _channelVideos[channelId] = [];
        _loadingVideos[channelId] = false;
      });
    }
  }

  Future<void> _togglePlayPause(String videoId, String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Audio file not found: $filePath')),
      );
      return;
    }
    await DownloadService.playOrPause(videoId, filePath);
  }

  Future<void> _syncChannel(Channel channel) async {
    try {
      // Show loading indicator
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Syncing ${channel.name}...')),
      );

      // Fetch all videos for the channel
      final videos = await YouTubeService.fetchChannelVideos(channel.id);
      if (videos.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No videos found for ${channel.name}')),
        );
        return;
      }

      // Sort videos by published date (newest first)
      videos.sort((a, b) => b.published.compareTo(a.published));

      // Find videos that are not already downloaded
      List<Video> videosToDownload = [];
      for (final video in videos) { // Check all available videos
        final isDownloaded = await DownloadService.isVideoDownloaded(video.id);
        if (!isDownloaded) {
          videosToDownload.add(video);
          if (videosToDownload.length >= 3) break; // Limit to 3 videos for sync, but show all in UI
        }
      }

      if (videosToDownload.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('All recent videos from ${channel.name} are already downloaded')),
        );
        return;
      }

      // Download videos in chronological order (oldest first)
      videosToDownload.sort((a, b) => a.published.compareTo(b.published));
      
      int downloadedCount = 0;
      String? lastDownloadedId;

      for (final video in videosToDownload) {
        setState(() {
          _downloading[video.id] = true;
          _downloadProgress[video.id] = 0.0;
        });

        final downloaded = await DownloadService.downloadAudio(
          videoId: video.id,
          videoUrl: 'https://www.youtube.com/watch?v=${video.id}',
          title: video.title,
          channelName: video.channelName,
          thumbnailUrl: video.thumbnailUrl,
          onProgress: (received, total) {
            if (!mounted) return;
            setState(() {
              _downloadProgress[video.id] = total > 0 ? received / total : 0.0;
            });
          },
        );

        setState(() {
          _downloading[video.id] = false;
          _downloadProgress[video.id] = 0.0;
        });

        if (downloaded != null) {
          downloadedCount++;
          lastDownloadedId = video.id;
          
          // Show notification for each download
          await NotificationService.showNotification(
            title: 'Sync Download Complete',
            body: 'Downloaded: ${video.title}',
          );
        }
      }
      if (!mounted) return;
      // Update the lastVideoId to the most recent downloaded video
      if (lastDownloadedId != null) {
        final updatedChannel = Channel(
          id: channel.id,
          name: channel.name,
          description: channel.description,
          thumbnailUrl: channel.thumbnailUrl,
          lastVideoId: lastDownloadedId,
        );
        await DatabaseService.instance.updateChannel(updatedChannel);
      }

      // Show final summary
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sync complete: Downloaded $downloadedCount videos from ${channel.name}')),
      );

      // Refresh the channel data
      await _loadChannels();
      await _fetchAndSetVideos(channel.id);

    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sync failed: $e')),
      );
    }
  }

  Future<void> _syncAllChannels() async {
    try {
      // Show loading indicator
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Syncing all channels...')),
      );

      int totalDownloaded = 0;
      int channelsProcessed = 0;

      for (final channel in _channels) {
        try {
          // Fetch all videos for the channel
          final videos = await YouTubeService.fetchChannelVideos(channel.id);
          if (videos.isEmpty) continue;

          // Sort videos by published date (newest first)
          videos.sort((a, b) => b.published.compareTo(a.published));

          // Find videos that are not already downloaded
          List<Video> videosToDownload = [];
          for (final video in videos.take(10)) { // Check first 10 videos
            final isDownloaded = await DownloadService.isVideoDownloaded(video.id);
            if (!isDownloaded) {
              videosToDownload.add(video);
              if (videosToDownload.length >= 5) break; // Limit to 5 videos
            }
          }

          if (videosToDownload.isNotEmpty) {
            // Download videos in chronological order (oldest first)
            videosToDownload.sort((a, b) => a.published.compareTo(b.published));
            
            String? lastDownloadedId;

            for (final video in videosToDownload) {
              final downloaded = await DownloadService.downloadAudio(
                videoId: video.id,
                videoUrl: 'https://www.youtube.com/watch?v=${video.id}',
                title: video.title,
                channelName: video.channelName,
                thumbnailUrl: video.thumbnailUrl,
              );

              if (downloaded != null) {
                totalDownloaded++;
                lastDownloadedId = video.id;
                
                // Show notification for each download
                await NotificationService.showNotification(
                  title: 'Sync Download Complete',
                  body: 'Downloaded: ${video.title} from ${channel.name}',
                );
              }
            }

            // Update the lastVideoId to the most recent downloaded video
            if (lastDownloadedId != null) {
              final updatedChannel = Channel(
                id: channel.id,
                name: channel.name,
                description: channel.description,
                thumbnailUrl: channel.thumbnailUrl,
                lastVideoId: lastDownloadedId,
              );
              await DatabaseService.instance.updateChannel(updatedChannel);
            }
          }

          channelsProcessed++;
          
          // Update progress
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Processed $channelsProcessed/${_channels.length} channels...')),
          );

        } catch (e) {
          if (!mounted) return;
          print('Error syncing channel ${channel.name}: $e');
          // Continue with other channels even if one fails
        }
      }

      // Show final summary
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Global sync complete: Downloaded $totalDownloaded videos from $channelsProcessed channels')),
      );

      // Refresh all channel data
      await _loadChannels();
      for (final channel in _channels) {
        await _fetchAndSetVideos(channel.id);
      }

    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Global sync failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final double screenWidth = MediaQuery.of(context).size.width;
    final double thumbnailSize = screenWidth * 0.22; // Responsive thumbnail

    return Scaffold(
      appBar: AppBar(
        title: Text('YT AudioBox', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22)),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0.5,
        actions: [
          IconButton(
            icon: Icon(Icons.sync),
            tooltip: 'Sync All Channels',
            onPressed: _channels.isEmpty ? null : () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text('Sync All Channels'),
                  content: Text('This will download up to 3 older videos from each channel. Continue?'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      child: Text('Sync All'),
                    ),
                  ],
                ),
              );
              if (confirm == true) {
                await _syncAllChannels();
              }
            },
          ),
        IconButton(
          icon: Icon(Icons.download),
            tooltip: 'Downloads',
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => DownloadManagerScreen()),
          ),
        ),
        ],
      ),
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Stack(
          children: [
            Column(
        children: [
                SizedBox(height: _showLogo ? 120 : 0),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: ChannelSearchField(
            onChannelSelected: _onChannelSelected,
            onManualAdd: _addChannel,
                  ),
          ),
          Expanded(
                  child: _channels.isEmpty
                      ? Center(child: Text('No channels added yet.', style: TextStyle(fontSize: 16, color: Colors.grey[600])))
                      : ListView.separated(
                          padding: EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                          separatorBuilder: (_, __) => SizedBox(height: 12),
              itemCount: _channels.length,
              itemBuilder: (context, i) {
                final channel = _channels[i];
                final videos = _channelVideos[channel.id] ?? [];
                final isLoading = _loadingVideos[channel.id] ?? false;
                return Card(
                              elevation: 3,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                              margin: EdgeInsets.zero,
                  child: ExpansionTile(
                                tilePadding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                childrenPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                                title: Row(
                                  children: [
                                    CircleAvatar(
                                      backgroundImage: channel.thumbnailUrl.isNotEmpty ? NetworkImage(channel.thumbnailUrl) : null,
                                      backgroundColor: Colors.red[100],
                                      radius: 20,
                                      child: channel.thumbnailUrl.isEmpty ? Icon(Icons.person, color: Colors.red[700]) : null,
                                    ),
                                    SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        channel.name,
                                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: Icon(Icons.sync),
                                      tooltip: 'Sync Channel (Download older videos)',
                                      onPressed: () async {
                                        final confirm = await showDialog<bool>(
                                          context: context,
                                          builder: (context) => AlertDialog(
                                            title: Text('Sync Channel'),
                                            content: Text('This will download up to 3 older videos from "${channel.name}". Continue?'),
                                            actions: [
                                              TextButton(
                                                onPressed: () => Navigator.of(context).pop(false),
                                                child: Text('Cancel'),
                                              ),
                                              TextButton(
                                                onPressed: () => Navigator.of(context).pop(true),
                                                child: Text('Sync'),
                                              ),
                                            ],
                                          ),
                                        );
                                        if (confirm == true) {
                                          await _syncChannel(channel);
                                        }
                                      },
                                    ),
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
                                      child: Text('No videos found.', style: TextStyle(color: Colors.grey[600])),
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
                                            ? Image.network(
                                                video.thumbnailUrl,
                                                        width: 80,
                                                        height: 45,
                                                fit: BoxFit.cover,
                                              )
                                            : Container(
                                                        width: 80,
                                                        height: 45,
                                                color: Colors.grey[300],
                                              ),
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
                                                    FutureBuilder<bool>(
                                                future: DownloadService.isVideoDownloaded(video.id),
                                                builder: (context, snapshot) {
                                                  final isDownloaded = snapshot.data ?? false;
                                                  final isDownloading = _downloading[video.id] ?? false;
                                                  final progress = _downloadProgress[video.id] ?? 0.0;
                                                  if (isDownloading) {
                                                          return Row(
                                                        children: [
                                                              Flexible(
                                                                child: LinearProgressIndicator(
                                                                  value: progress > 0 ? progress : null,
                                                                  minHeight: 4,
                                                                ),
                                                              ),
                                                              SizedBox(width: 8),
                                                              SizedBox(
                                                                width: 48,
                                                                child: Text(
                                                                  progress > 0 ? '${(progress * 100).toStringAsFixed(0)}%' : 'Downloading...',
                                                                  style: TextStyle(fontSize: 12),
                                                                  overflow: TextOverflow.ellipsis,
                                                                ),
                                                              ),
                                                              IconButton(
                                                                icon: Icon(Icons.close, size: 20, color: Colors.red),
                                                                tooltip: 'Cancel Download',
                                                                onPressed: () async {
                                                                  final scaffoldMessenger = ScaffoldMessenger.of(context);
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
                                                                      _downloadProgress[video.id] = 0.0;
                                                                    });
                                                                    if (!mounted) return;
                                                                    scaffoldMessenger.showSnackBar(
                                                                      SnackBar(content: Text('Download cancelled')),
                                                                    );
                                                                  }
                                                                },
                                                              ),
                                                            ],
                                                    );
                                                  }
                                                  return ValueListenableBuilder<PlayingAudio?>(
                                                    valueListenable: DownloadService.globalPlayingNotifier,
                                                    builder: (context, playing, _) {
                                                      final isThisPlaying = (playing?.videoId == video.id) && (playing?.isPlaying ?? false);
                                                            return Row(
                                                              children: [
                                                                ElevatedButton.icon(
                                                                  style: ElevatedButton.styleFrom(
                                                                    backgroundColor: isDownloaded ? Colors.green[600] : Colors.red[600],
                                                                    foregroundColor: Colors.white,
                                                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                                                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                                                  ),
                                                        icon: Icon(
                                                          isThisPlaying
                                                              ? Icons.pause
                                                              : isDownloaded
                                                                  ? Icons.play_arrow
                                                                  : Icons.download,
                                                                    size: 20,
                                                        ),
                                                        label: Text(
                                                          isThisPlaying
                                                              ? 'Pause'
                                                              : isDownloaded
                                                                  ? 'Play'
                                                                  : 'Download',
                                                                    style: TextStyle(fontWeight: FontWeight.w500),
                                                        ),
                                                onPressed: () async {
                                                  if (isDownloaded) {
                                                    final filePath = await DownloadService.getDownloadedFilePath(video.id);
                                                    if (filePath != null) {
                                                              await _togglePlayPause(video.id, filePath);
                                                    }
                                                  } else {
                                                            setState(() {
                                                              _downloading[video.id] = true;
                                                              _downloadProgress[video.id] = 0.0;
                                                            });
                                                            if (!mounted) return;
                                                            ScaffoldMessenger.of(context).showSnackBar(
                                                              SnackBar(content: Text('Download started: ${video.title}')),
                                                            );
                                                                      await DownloadService.downloadAudio(
                                                      videoId: video.id,
                                                      videoUrl: 'https://www.youtube.com/watch?v=${video.id}',
                                                      title: video.title,
                                                      channelName: video.channelName,
                                                      thumbnailUrl: video.thumbnailUrl,
                                                              onProgress: (received, total) {
                                                                if (!mounted) return;
                                                                setState(() {
                                                                  _downloadProgress[video.id] = total > 0 ? received / total : 0.0;
                                                                });
                                                              },
                                                    );
                                                            if (!mounted) return;
                                                            setState(() {
                                                              _downloading[video.id] = false;
                                                              _downloadProgress[video.id] = 0.0;
                                                            });
                                                              if (!mounted) return;
                                                              ScaffoldMessenger.of(context).showSnackBar(
                                                                SnackBar(content: Text('Download complete: ${video.title}')),
                                                              );
                                                                    }
                                                                  },
                                                                ),
                                                              ],
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
                );
              },
            ),
          ),
              ],
            ),
            // Animated logo overlay
            if (_showLogo)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SlideTransition(
                  position: _slideAnimation,
                  child: FadeTransition(
                    opacity: _fadeAnimation,
                    child: Container(
                      color: Colors.white,
                      padding: EdgeInsets.only(top: 48, bottom: 24),
                      alignment: Alignment.center,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Image.asset('assets/splash_logo.png', width: 120),
                          SizedBox(height: 16),
                          Text('YT AudioBox', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.red[700])),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            // MiniPlayer at the bottom, outside the Column
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: MiniPlayer(),
            ),
        ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          AudioPlayerBottomSheet.show(context);
        },
        child: Icon(Icons.music_note),
        tooltip: 'Audio Controls',
        backgroundColor: Colors.red[600],
        foregroundColor: Colors.white,
        elevation: 2,
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
  await dbClient.insert('downloaded_videos', video.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
}

Future<DownloadedVideo?> getDownloadedVideo(String videoId) async {
  final dbClient = await DatabaseService.instance.db;
  final maps = await dbClient.query('downloaded_videos', where: 'videoId = ?', whereArgs: [videoId]);
  if (maps.isNotEmpty) {
    return DownloadedVideo.fromMap(maps.first);
  }
  return null;
} 