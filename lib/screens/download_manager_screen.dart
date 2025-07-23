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

class DownloadManagerScreen extends StatefulWidget {
  @override
  _DownloadManagerScreenState createState() => _DownloadManagerScreenState();
}

class _DownloadManagerScreenState extends State<DownloadManagerScreen> {
  List<DownloadedVideo> _downloadedVideos = [];
  static List<DownloadedVideo> _cachedCompletedDownloads = [];
  bool _isLoading = true; // Start as true for the very first load
  bool _hasEverLoadedCompleted = false;
  bool _hasInProgressDownloads = false;
  bool _instantInProgress = false;
  List<File> _orphanedFiles = [];
  bool _scannedForOrphans = false;

  @override
  void initState() {
    super.initState();
    // If we have a cache from a previous session, use it immediately
    if (_cachedCompletedDownloads.isNotEmpty) {
      _hasEverLoadedCompleted = true;
      _isLoading = false;
    }
    // Listen to instant in-progress notifier
    _instantInProgress = DownloadService.isAnyDownloadInProgress.value;
    DownloadService.isAnyDownloadInProgress.addListener(_instantInProgressListener);
    _loadDownloadedVideos();
    DownloadService.downloadedVideosChanged.addListener(_loadDownloadedVideos);
    _scanForOrphanedFiles();
  }

  void _instantInProgressListener() {
    if (mounted) setState(() {
      _instantInProgress = DownloadService.isAnyDownloadInProgress.value;
    });
  }

  @override
  void dispose() {
    DownloadService.downloadedVideosChanged.removeListener(_loadDownloadedVideos);
    DownloadService.isAnyDownloadInProgress.removeListener(_instantInProgressListener);
    super.dispose();
  }

  Future<void> _loadDownloadedVideos() async {
    print('[DownloadManagerScreen] Loading downloaded videos...');
    final videos = await DatabaseService.instance.getDownloadedVideos();
    print('[DownloadManagerScreen] Loaded ${videos.length} videos from DB');
    await Future.delayed(Duration(milliseconds: 100));
    final completed = videos.where((v) => v.status == 'completed').toList();
    final inProgress = videos.where((v) => v.status == 'downloading').toList();
    print('[DownloadManagerScreen] Completed downloads: ${completed.length}, In-progress: ${inProgress.length}');
    if (mounted) setState(() {
      _downloadedVideos = [...inProgress, ...completed];
      _hasInProgressDownloads = inProgress.isNotEmpty;
      if (completed.isNotEmpty) {
        _cachedCompletedDownloads = completed;
        _hasEverLoadedCompleted = true;
      }
      _isLoading = false;
    });
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
    final showSpinner = _isLoading && !_hasEverLoadedCompleted && _cachedCompletedDownloads.isEmpty && !_instantInProgress;
    final displayList = _downloadedVideos.isNotEmpty ? _downloadedVideos : _cachedCompletedDownloads;
    print('[DownloadManagerScreen] build: showSpinner=$showSpinner, displayList.length=${displayList.length}, _isLoading=$_isLoading, _hasEverLoadedCompleted=$_hasEverLoadedCompleted, _hasInProgressDownloads=$_hasInProgressDownloads, _instantInProgress=$_instantInProgress');
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
                  : ValueListenableBuilder<Map<String, double>>(
                      valueListenable: DownloadService.downloadProgressNotifier,
                      builder: (context, progressMap, _) {
                        // Always fetch the latest in-progress downloads from the DB and progressMap
                        final allVideoIds = <String>{};
                        final inProgressVideos = <DownloadedVideo>[];
                        // Add all DB in-progress
                        for (final v in _downloadedVideos.where((v) => v.status == 'downloading')) {
                          inProgressVideos.add(v);
                          allVideoIds.add(v.videoId);
                        }
                        // Add any in-progress from progressMap not in DB list
                        for (final entry in progressMap.entries) {
                          if (!allVideoIds.contains(entry.key)) {
                            // Try to get info from DB (should be present)
                            final idx = _downloadedVideos.indexWhere((v) => v.videoId == entry.key);
                            if (idx != -1) {
                              inProgressVideos.add(_downloadedVideos[idx]);
                              allVideoIds.add(entry.key);
                            }
                          }
                        }
                        // If still missing, fetch from DB (for immediate UI update after manual start)
                        for (final videoId in progressMap.keys) {
                          if (!allVideoIds.contains(videoId)) {
                            // This is a new in-progress download not yet in _downloadedVideos
                            // Try to fetch from DB synchronously (not ideal, but for UI immediacy)
                            // (In practice, _loadDownloadedVideos should be called after manual start)
                          }
                        }
                        final completedList = _downloadedVideos.where((v) => v.status == 'completed').toList();
                        final hasAny = inProgressVideos.isNotEmpty || completedList.isNotEmpty;
                        if (!hasAny) {
                          return Center(
                            child: Text('No downloads yet.', style: TextStyle(fontSize: 16, color: Colors.grey[600])),
                          );
                        }
                        return ListView.separated(
                          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          separatorBuilder: (_, __) => SizedBox(height: 10),
                          itemCount: inProgressVideos.length + completedList.length,
                    itemBuilder: (context, i) {
                            if (i < inProgressVideos.length) {
                              final video = inProgressVideos[i];
                              final progress = progressMap[video.videoId] ?? 0.0;
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
                                      LinearProgressIndicator(
                                        value: progress,
                                        minHeight: 4,
                                        backgroundColor: Colors.grey.shade300,
                                        valueColor: AlwaysStoppedAnimation<Color>(Colors.orange),
                                      ),
                                      SizedBox(height: 4),
                                      Text('Downloading... ${(progress * 100).toStringAsFixed(0)}%', style: TextStyle(fontSize: 13, color: Colors.orange[800], fontWeight: FontWeight.w500)),
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
                            } else {
                              final video = completedList[i - inProgressVideos.length];
                              return Card(
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
                              );
                            }
                  },
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