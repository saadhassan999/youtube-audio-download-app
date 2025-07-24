import 'package:flutter/material.dart';
import '../models/downloaded_video.dart';
import '../services/database_service.dart';
import '../services/download_service.dart';
import '../widgets/mini_player.dart';
import '../widgets/audio_player_bottom_sheet.dart';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:just_audio/just_audio.dart';
import 'dart:async';
import 'package:flutter_media_metadata/flutter_media_metadata.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/widgets.dart';
import '../../main.dart';

class DownloadManagerScreen extends StatefulWidget {
  @override
  _DownloadManagerScreenState createState() => _DownloadManagerScreenState();
}

class _DownloadManagerScreenState extends State<DownloadManagerScreen> with RouteAware {
  // Static cache for instant load
  static List<DownloadedVideo> _cachedVideos = [];
  final ValueNotifier<List<DownloadedVideo>> downloadedVideosNotifier = ValueNotifier([]);
  bool _isLoading = true;
  bool _scannedForOrphans = false;
  List<File> _orphanedFiles = [];

  @override
  void initState() {
    super.initState();
    // Show cached data instantly
    if (_cachedVideos.isNotEmpty) {
      downloadedVideosNotifier.value = List.from(_cachedVideos);
      _isLoading = false;
    }
    DownloadService.isAnyDownloadInProgress.addListener(_instantInProgressListener);
    _loadDownloadedVideos();
    DownloadService.downloadedVideosChanged.addListener(_loadDownloadedVideos);
    _scanForOrphanedFiles();
    DownloadService.resumeIncompleteDownloads();
  }

  void _instantInProgressListener() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    routeObserver.subscribe(this, ModalRoute.of(context) as PageRoute);
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    DownloadService.downloadedVideosChanged.removeListener(_loadDownloadedVideos);
    DownloadService.isAnyDownloadInProgress.removeListener(_instantInProgressListener);
    super.dispose();
  }

  @override
  void didPopNext() {
    DownloadService.resumeIncompleteDownloads();
    _loadDownloadedVideos();
  }

  Future<void> _loadDownloadedVideos() async {
    final videos = await DatabaseService.instance.getDownloadedVideos();
    _cachedVideos = List.from(videos); // update cache
    downloadedVideosNotifier.value = List.from(videos);
    if (_isLoading) {
      setState(() {
        _isLoading = false;
      });
    } else {
      setState(() {});
    }
  }

  Future<void> _scanForOrphanedFiles() async {
    final dir = await getApplicationDocumentsDirectory();
    final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.mp3')).toList();
    final dbVideos = await DatabaseService.instance.getDownloadedVideos();
    final dbPaths = dbVideos.map((v) => v.filePath).toSet();
    setState(() {
      _orphanedFiles = files.where((f) => !dbPaths.contains(f.path)).toList();
      _scannedForOrphans = true;
    });
  }

  Future<void> _repairOrphanedFiles() async {
    for (final file in _orphanedFiles) {
      try {
        final metadata = await MetadataRetriever.fromFile(file);
        final title = metadata.trackName ?? file.uri.pathSegments.last;
        final channelName = metadata.albumName ?? '';
        final duration = metadata.trackDuration != null ? Duration(milliseconds: metadata.trackDuration!) : null;
        final videoId = file.uri.pathSegments.last.replaceAll('.mp3', '');
        final downloadedAt = file.statSync().modified;
        final completedVideo = DownloadedVideo(
          videoId: videoId,
          title: title,
          filePath: file.path,
          size: await file.length(),
          duration: duration,
          channelName: channelName,
          thumbnailUrl: '',
          downloadedAt: downloadedAt,
          status: 'completed',
        );
        await DatabaseService.instance.addDownloadedVideo(completedVideo);
      } catch (e) {
        // Could not extract metadata, skip
      }
    }
    await _loadDownloadedVideos();
    await _scanForOrphanedFiles();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Orphaned files repaired.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final showSpinner = _isLoading && downloadedVideosNotifier.value.isEmpty;
    return Scaffold(
      appBar: AppBar(
        title: Text('Downloads', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22)),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0.5,
        actions: [
          if (_orphanedFiles.isNotEmpty)
            IconButton(
              icon: Icon(Icons.build),
              tooltip: 'Repair Orphaned Files',
              onPressed: _repairOrphanedFiles,
            ),
        ],
      ),
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            if (_orphanedFiles.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Row(
                  children: [
                    Icon(Icons.warning, color: Colors.orange),
                    SizedBox(width: 8),
                    Expanded(child: Text('Found ${_orphanedFiles.length} audio files not in the database. Tap the wrench to repair.')),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Icon(Icons.library_music, color: Colors.red[600]),
                  SizedBox(width: 8),
                  Text('Downloaded Audio', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                ],
              ),
            ),
            Expanded(
              child: showSpinner
                  ? Center(child: CircularProgressIndicator())
                  : ValueListenableBuilder<List<DownloadedVideo>>(
                      valueListenable: downloadedVideosNotifier,
                      builder: (context, videos, _) {
                        final inProgressVideos = videos.where((v) => v.status == 'downloading').toList();
                        final completedList = videos.where((v) => v.status == 'completed').toList();
                        return ListView(
                          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          children: [
                            // In-Progress Section
                            Text('In-Progress', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.orange[800])),
                            if (inProgressVideos.isEmpty)
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                child: Text('No active downloads.', style: TextStyle(color: Colors.grey[600])),
                              ),
                            ...inProgressVideos.map((video) {
                              return Card(
                                color: Colors.yellow[50],
                                elevation: 2,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                child: ListTile(
                                  leading: video.thumbnailUrl.isNotEmpty
                                      ? Image.network(video.thumbnailUrl, width: 56, height: 56, fit: BoxFit.cover)
                                      : Icon(Icons.music_note, size: 56),
                                  title: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(video.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.bold)),
                                      SizedBox(height: 4),
                                      ValueListenableBuilder<Map<String, double>>(
                                        valueListenable: DownloadService.downloadProgressNotifier,
                                        builder: (context, progressMap, _) {
                                          final progress = progressMap[video.videoId] ?? 0.0;
                                          return Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              LinearProgressIndicator(
                                                value: progress > 0 ? progress : null, // null = indeterminate
                                                minHeight: 4,
                                                backgroundColor: Colors.grey.shade300,
                                                valueColor: AlwaysStoppedAnimation<Color>(Colors.orange),
                                              ),
                                              SizedBox(height: 4),
                                              Text(
                                                progress > 0
                                                  ? 'Downloading... ${(progress * 100).toStringAsFixed(0)}%'
                                                  : 'Downloading...',
                                                style: TextStyle(fontSize: 13, color: Colors.orange[800], fontWeight: FontWeight.w500),
                                              ),
                                            ],
                                          );
                                        },
                                      ),
                                    ],
                                  ),
                                  subtitle: Text(video.channelName),
                                  trailing: IconButton(
                                    icon: Icon(Icons.close, color: Colors.red),
                                    tooltip: 'Cancel Download',
                                    onPressed: () async {
                                      await DownloadService.cancelDownload(video.videoId);
                                      await _loadDownloadedVideos();
                                    },
                                  ),
                                  contentPadding: EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                                ),
                              );
                            }),
                            SizedBox(height: 18),
                            // Completed Section
                            Text('Completed', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.green[800])),
                            if (completedList.isEmpty)
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                child: Text('No completed downloads.', style: TextStyle(color: Colors.grey[600])),
                              ),
                            ...completedList.map((video) => Card(
                              elevation: 2,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                              child: _AudioProgressListTile(
                                video: video,
                                onDelete: () async {
                                  final confirm = await showDialog<bool>(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                      title: Text('Delete Audio'),
                                      content: Text('Are you sure you want to delete this audio?'),
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
                                    await DownloadService.deleteDownloadedAudio(video.videoId);
                                    await _loadDownloadedVideos();
                                    if (!mounted) return;
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('Deleted: ${video.title}')),
                                    );
                                  }
                                },
                              ),
                            )),
                          ],
                        );
                      },
                    ),
            ),
            MiniPlayer(),
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

class _AudioProgressListTile extends StatefulWidget {
  final DownloadedVideo video;
  final VoidCallback onDelete;
  const _AudioProgressListTile({Key? key, required this.video, required this.onDelete}) : super(key: key);

  @override
  State<_AudioProgressListTile> createState() => _AudioProgressListTileState();
}

class _AudioProgressListTileState extends State<_AudioProgressListTile> {
  double _progress = 0.0;
  int _durationMs = 0;
  StreamSubscription<Duration>? _positionSub;
  late VoidCallback _globalPlayingNotifierListener;

  @override
  void initState() {
    super.initState();
    _loadInitialProgress();
    _globalPlayingNotifierListener = () {
      _updateProgressAndListeningState();
    };
    DownloadService.globalPlayingNotifier.addListener(_globalPlayingNotifierListener);
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    DownloadService.globalPlayingNotifier.removeListener(_globalPlayingNotifierListener);
    super.dispose();
  }

  void _updateProgressAndListeningState() async {
    final playing = DownloadService.globalPlayingNotifier.value;
    final isThisAudioCurrentlyPlaying = (playing?.videoId == widget.video.videoId) && (playing?.isPlaying ?? false);

    if (isThisAudioCurrentlyPlaying) {
      _positionSub?.cancel();
      _positionSub = DownloadService.globalAudioPlayer.positionStream.listen((pos) {
        if (_durationMs > 0) {
          setState(() {
            _progress = pos.inMilliseconds / _durationMs;
            if (_progress > 1.0) _progress = 1.0;
          });
        }
        _saveProgressToPrefs(pos.inMilliseconds);
      });
    } else {
      _positionSub?.cancel();
      await _loadInitialProgress();
    }
  }

  Future<void> _loadInitialProgress() async {
    final prefs = await SharedPreferences.getInstance();
    final position = prefs.getInt('audio_position_${widget.video.videoId}') ?? 0;
    int duration = widget.video.duration?.inMilliseconds ?? 0;
    if (duration == 0) {
      try {
        final metadata = await MetadataRetriever.fromFile(File(widget.video.filePath));
        duration = metadata.trackDuration ?? 0;
      } catch (_) {
        duration = 0;
      }
    }
    double calculatedProgress = 0.0;
    if (duration > 0) {
      calculatedProgress = position / duration;
      if (calculatedProgress > 1.0) calculatedProgress = 1.0;
    }
    if (mounted) {
      setState(() {
        _progress = calculatedProgress;
        _durationMs = duration;
      });
    }
  }

  Future<void> _saveProgressToPrefs(int positionMs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('audio_position_${widget.video.videoId}', positionMs);
  }

  @override
  Widget build(BuildContext context) {
    final video = widget.video;
    return ValueListenableBuilder<PlayingAudio?>(
      valueListenable: DownloadService.globalPlayingNotifier,
      builder: (context, playing, _) {
        final isPlayingThisAudio = (playing?.videoId == video.videoId) && (playing?.isPlaying ?? false);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _updateProgressAndListeningState();
        });
        Color barColor;
        if (_progress >= 0.95) {
          barColor = Colors.green;
        } else if (_progress > 0.0) {
          barColor = Colors.red;
        } else {
          barColor = Colors.grey;
        }
        return ListTile(
          leading: video.thumbnailUrl.isNotEmpty
              ? Image.network(video.thumbnailUrl, width: 56, height: 56, fit: BoxFit.cover)
              : Icon(Icons.music_note, size: 56),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(video.title, maxLines: 2, overflow: TextOverflow.ellipsis),
              SizedBox(height: 4),
              LinearProgressIndicator(
                value: _progress,
                minHeight: 4,
                backgroundColor: Colors.grey.shade300,
                valueColor: AlwaysStoppedAnimation<Color>(barColor),
              ),
            ],
          ),
          subtitle: Text(video.channelName),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: Icon(isPlayingThisAudio ? Icons.pause : Icons.play_arrow),
                tooltip: isPlayingThisAudio ? 'Pause' : 'Play',
                onPressed: () async {
                  final file = File(video.filePath);
                  if (!await file.exists()) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Audio file not found: ${video.filePath}')),
                    );
                    return;
                  }
                  final prefs = await SharedPreferences.getInstance();
                  final lastPos = prefs.getInt('audio_position_${video.videoId}') ?? 0;
                  await DownloadService.playOrPause(
                    video.videoId,
                    video.filePath,
                    title: video.title,
                    channelName: video.channelName,
                    thumbnailUrl: video.thumbnailUrl,
                  );
                  if (lastPos > 0) {
                    await DownloadService.globalAudioPlayer.seek(Duration(milliseconds: lastPos));
                  }
                },
              ),
              IconButton(
                icon: Icon(Icons.delete),
                onPressed: widget.onDelete,
              ),
            ],
          ),
          contentPadding: EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          onTap: () async {
            final file = File(video.filePath);
            if (!await file.exists()) {
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Audio file not found: ${video.filePath}')),
              );
              return;
            }
            final prefs = await SharedPreferences.getInstance();
            final lastPos = prefs.getInt('audio_position_${video.videoId}') ?? 0;
            await DownloadService.playOrPause(
              video.videoId,
              video.filePath,
              title: video.title,
              channelName: video.channelName,
              thumbnailUrl: video.thumbnailUrl,
            );
            if (lastPos > 0) {
              await DownloadService.globalAudioPlayer.seek(Duration(milliseconds: lastPos));
            }
          },
        );
      },
    );
  }
} 