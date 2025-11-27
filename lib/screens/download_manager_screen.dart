import 'package:flutter/material.dart';
import '../models/downloaded_video.dart';
import '../services/database_service.dart';
import '../services/download_service.dart';
import '../widgets/mini_player.dart';
import 'dart:io';
import 'dart:isolate';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'package:flutter_media_metadata/flutter_media_metadata.dart';
import 'package:path_provider/path_provider.dart';
import '../../main.dart';
import '../core/snackbar_bus.dart';
import '../repositories/download_repository.dart';
import 'package:flutter/scheduler.dart';

class DownloadManagerScreen extends StatefulWidget {
  const DownloadManagerScreen({super.key});

  @override
  _DownloadManagerScreenState createState() => _DownloadManagerScreenState();
}

class _DownloadManagerScreenState extends State<DownloadManagerScreen>
    with RouteAware {
  final DownloadRepository _downloadRepository = DownloadRepository.instance;
  final ValueNotifier<List<DownloadedVideo>> downloadedVideosNotifier =
      ValueNotifier([]);
  bool _isLoading = true;
  bool _isRefreshing = false;
  String? _lastRefreshError;
  Future<void>? _refreshInFlight;
  List<String> _orphanedFiles = [];
  late final VoidCallback _downloadsChangedListener;

  @override
  void initState() {
    super.initState();
    final cached = _downloadRepository.cached;
    if (cached.isNotEmpty) {
      downloadedVideosNotifier.value = List.from(cached);
      _isLoading = false;
    }
    DownloadService.isAnyDownloadInProgress.addListener(
      _instantInProgressListener,
    );
    unawaited(_loadDownloadedVideos(forceRefresh: cached.isEmpty));
    _downloadsChangedListener = () {
      unawaited(_loadDownloadedVideos(forceRefresh: true));
    };
    DownloadService.downloadedVideosChanged.addListener(
      _downloadsChangedListener,
    );
    // Defer heavy file scanning until after first frame to keep first paint smooth.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      unawaited(_scanForOrphanedFiles());
    });
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
    DownloadService.downloadedVideosChanged.removeListener(
      _downloadsChangedListener,
    );
    DownloadService.isAnyDownloadInProgress.removeListener(
      _instantInProgressListener,
    );
    super.dispose();
  }

  @override
  void didPopNext() {
    DownloadService.resumeIncompleteDownloads();
    unawaited(_loadDownloadedVideos(forceRefresh: true));
  }

  Future<void> _loadDownloadedVideos({bool forceRefresh = false}) async {
    try {
      final videos = await _downloadRepository.fetchDownloads(
        forceRefresh: forceRefresh,
      );
      _downloadRepository.replaceCache(videos);
      downloadedVideosNotifier.value = List.from(videos);
      if (!mounted) return;
      setState(() {
        _lastRefreshError = null;
        if (_isLoading) {
          _isLoading = false;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _lastRefreshError = 'Failed to load downloads.';
        _isLoading = false;
      });
      showGlobalSnackBar(
        SnackBar(content: Text('Failed to load downloads: $e')),
      );
    }
  }

  Future<void> _refreshDownloads() {
    final inFlight = _refreshInFlight;
    if (inFlight != null) return inFlight;

    final future = _doRefreshDownloads();
    _refreshInFlight = future;
    return future.whenComplete(() {
      _refreshInFlight = null;
    });
  }

  Future<void> _doRefreshDownloads() async {
    if (!mounted) return;
    setState(() {
      _isRefreshing = true;
    });

    try {
      await _loadDownloadedVideos(forceRefresh: true);
    } finally {
      if (!mounted) return;
      setState(() {
        _isRefreshing = false;
      });
    }
  }

  Widget _buildRefreshButton({
    required String label,
    required bool isBusy,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        onPressed: isBusy
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

  Future<void> _scanForOrphanedFiles() async {
    final dbVideos = await DatabaseService.instance.getDownloadedVideos();
    final dbPaths = dbVideos
        .map((v) => v.filePath)
        .whereType<String>()
        .toList(growable: false);
    final dir = await getApplicationDocumentsDirectory();
    final orphanPaths = await _findOrphanedFilePaths(dir.path, dbPaths);
    if (!mounted) return;
    setState(() {
      _orphanedFiles = orphanPaths;
    });
  }

  Future<void> _repairOrphanedFiles() async {
    for (final file in _orphanedFiles) {
      try {
        final fileHandle = File(file);
        final metadata = await MetadataRetriever.fromFile(fileHandle);
        final title = metadata.trackName ?? fileHandle.uri.pathSegments.last;
        final channelName = metadata.albumName ?? '';
        final duration = metadata.trackDuration != null
            ? Duration(milliseconds: metadata.trackDuration!)
            : null;
        final videoId = fileHandle.uri.pathSegments.last.replaceAll(
          '.mp3',
          '',
        );
        final downloadedAt = fileHandle.statSync().modified;
        final completedVideo = DownloadedVideo(
          videoId: videoId,
          title: title,
          filePath: fileHandle.path,
          size: await fileHandle.length(),
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
    await _loadDownloadedVideos(forceRefresh: true);
    await _scanForOrphanedFiles();
    if (!mounted) return;
    showGlobalSnackBar(SnackBar(content: Text('Orphaned files repaired.')));
  }

  @override
  Widget build(BuildContext context) {
    final showSpinner = _isLoading && downloadedVideosNotifier.value.isEmpty;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Downloads',
          style:
              theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurface,
              ) ??
              TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 22,
                color: colorScheme.onSurface,
              ),
        ),
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.onSurface,
        elevation: 0.5,
        actions: [
          if (_orphanedFiles.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.build),
              tooltip: 'Repair Orphaned Files',
              onPressed: _repairOrphanedFiles,
            ),
        ],
      ),
      backgroundColor: theme.scaffoldBackgroundColor,
      bottomNavigationBar: const MiniPlayerHost(),
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
                    Expanded(
                      child: Text(
                        'Found ${_orphanedFiles.length} audio files not in the database. Tap the wrench to repair.',
                      ),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Icon(Icons.library_music, color: Colors.red[600]),
                  SizedBox(width: 8),
                  Text(
                    'Downloaded Audio',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                ],
              ),
            ),
            Expanded(
              child: showSpinner
                  ? const Center(child: CircularProgressIndicator())
                  : RefreshIndicator(
                      onRefresh: _refreshDownloads,
                      displacement: 72,
                      child: ValueListenableBuilder<List<DownloadedVideo>>(
                        valueListenable: downloadedVideosNotifier,
                        builder: (context, videos, _) {
                          final inProgressVideos = videos
                              .where((v) => v.status == 'downloading')
                              .toList();
                          final completedList = videos
                              .where((v) => v.status == 'completed')
                              .toList();

                          if (videos.isEmpty) {
                            final message =
                                _lastRefreshError ??
                                'No downloads yet. Pull down after reconnecting.';
                            return ListView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24,
                                vertical: 32,
                              ),
                              children: [
                                Text(
                                  message,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: Colors.grey[700]),
                                ),
                                if (_lastRefreshError != null)
                                  const SizedBox(height: 12),
                                if (_lastRefreshError != null)
                                  _buildRefreshButton(
                                    label: 'Retry',
                                    isBusy: _isRefreshing,
                                    onPressed: () => _refreshDownloads(),
                                  ),
                              ],
                            );
                          }

                          final rows = <_DownloadRow>[
                            if (_lastRefreshError != null)
                              _DownloadRow.error(_lastRefreshError!),
                            const _DownloadRow.header('In-Progress'),
                            if (inProgressVideos.isEmpty)
                              const _DownloadRow.message('No active downloads.')
                            else
                              ...inProgressVideos.map(
                                (video) => _DownloadRow.inProgress(video),
                              ),
                            const _DownloadRow.spacer(),
                            const _DownloadRow.header('Completed'),
                            if (completedList.isEmpty)
                              const _DownloadRow.message('No completed downloads.')
                            else
                              ...completedList.map(
                                (video) => _DownloadRow.completed(video),
                              ),
                          ];

                          return ListView.builder(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            itemCount: rows.length,
                            itemBuilder: (context, index) {
                              final row = rows[index];
                              switch (row.type) {
                                case _DownloadRowType.error:
                                  return Padding(
                                    padding:
                                        const EdgeInsets.only(bottom: 12),
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.info_outline,
                                          color: Colors.orange[800],
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            row.text!,
                                            style: TextStyle(
                                              color: Colors.orange[800],
                                            ),
                                          ),
                                        ),
                                        TextButton(
                                          onPressed: _isRefreshing
                                              ? null
                                              : () => _refreshDownloads(),
                                          child: _isRefreshing
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
                                  );
                                case _DownloadRowType.header:
                                  final isInProgress =
                                      row.text == 'In-Progress';
                                  return Text(
                                    row.text ?? '',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                      color: isInProgress
                                          ? Colors.orange[800]
                                          : Colors.green[800],
                                    ),
                                  );
                                case _DownloadRowType.message:
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                    child: Text(
                                      row.text ?? '',
                                      style:
                                          TextStyle(color: Colors.grey[600]),
                                    ),
                                  );
                                case _DownloadRowType.spacer:
                                  return const SizedBox(height: 18);
                                case _DownloadRowType.inProgress:
                                  final video = row.video!;
                                  return Card(
                                    color: Colors.yellow[50],
                                    elevation: 2,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    child: ListTile(
                                      leading: video.thumbnailUrl.isNotEmpty
                                          ? ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              child: Image.network(
                                                video.thumbnailUrl,
                                                width: 56,
                                                height: 56,
                                                fit: BoxFit.cover,
                                                errorBuilder:
                                                    (
                                                      context,
                                                      error,
                                                      stackTrace,
                                                    ) => Container(
                                                      width: 56,
                                                      height: 56,
                                                      color:
                                                          Colors.grey.shade300,
                                                      alignment:
                                                          Alignment.center,
                                                      child: Icon(
                                                        Icons.music_note,
                                                        color: Colors.grey[600],
                                                      ),
                                                    ),
                                              ),
                                            )
                                          : const Icon(
                                              Icons.music_note,
                                              size: 56,
                                            ),
                                      title: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            video.title,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          ValueListenableBuilder<
                                            Map<String, double>
                                          >(
                                            valueListenable: DownloadService
                                                .downloadProgressNotifier,
                                            builder:
                                                (context, progressMap, _) {
                                              final progress =
                                                  progressMap[video.videoId] ??
                                                  0.0;
                                              return Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  LinearProgressIndicator(
                                                    value: progress > 0
                                                        ? progress
                                                        : null,
                                                    minHeight: 4,
                                                    backgroundColor:
                                                        Colors.grey.shade300,
                                                    valueColor:
                                                        AlwaysStoppedAnimation<
                                                          Color
                                                        >(Colors.orange),
                                                  ),
                                                  const SizedBox(height: 4),
                                                  Text(
                                                    progress > 0
                                                        ? 'Downloading... ${(progress * 100).toStringAsFixed(0)}%'
                                                        : 'Downloading...',
                                                    style: TextStyle(
                                                      fontSize: 13,
                                                      color: Colors.orange[800],
                                                      fontWeight:
                                                          FontWeight.w500,
                                                    ),
                                                  ),
                                                ],
                                              );
                                            },
                                          ),
                                        ],
                                      ),
                                      subtitle: Text(video.channelName),
                                      trailing: IconButton(
                                        icon: const Icon(
                                          Icons.close,
                                          color: Colors.red,
                                        ),
                                        tooltip: 'Cancel Download',
                                        onPressed: () async {
                                          await DownloadService.cancelDownload(
                                            video.videoId,
                                          );
                                          await _loadDownloadedVideos(
                                            forceRefresh: true,
                                          );
                                        },
                                      ),
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                        vertical: 4,
                                        horizontal: 8,
                                      ),
                                    ),
                                  );
                                case _DownloadRowType.completed:
                                  final video = row.video!;
                                  return Card(
                                    elevation: 2,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    child: _AudioProgressListTile(
                                      video: video,
                                      onDelete: () async {
                                        final confirm =
                                            await showDialog<bool>(
                                          context: context,
                                          builder: (context) => AlertDialog(
                                            title: const Text('Delete Audio'),
                                            content: const Text(
                                              'Are you sure you want to delete this audio?',
                                            ),
                                            actions: [
                                              TextButton(
                                                onPressed: () => Navigator.of(
                                                  context,
                                                ).pop(false),
                                                child: const Text('No'),
                                              ),
                                              TextButton(
                                                onPressed: () => Navigator.of(
                                                  context,
                                                ).pop(true),
                                                child: const Text('Yes'),
                                              ),
                                            ],
                                          ),
                                        );
                                        if (confirm == true) {
                                          await DownloadService
                                              .deleteDownloadedAudio(
                                            video.videoId,
                                          );
                                          await _loadDownloadedVideos(
                                            forceRefresh: true,
                                          );
                                          if (!mounted) return;
                                          showGlobalSnackBar(
                                            SnackBar(
                                              content: Text(
                                                'Deleted: ${video.title}',
                                              ),
                                            ),
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
            ),
          ],
        ),
      ),
    );
  }
}

enum _DownloadRowType { header, inProgress, completed, message, spacer, error }

class _DownloadRow {
  const _DownloadRow._(this.type, {this.video, this.text});
  const _DownloadRow.header(String text)
      : this._(_DownloadRowType.header, text: text);
  const _DownloadRow.inProgress(DownloadedVideo video)
      : this._(_DownloadRowType.inProgress, video: video);
  const _DownloadRow.completed(DownloadedVideo video)
      : this._(_DownloadRowType.completed, video: video);
  const _DownloadRow.message(String text)
      : this._(_DownloadRowType.message, text: text);
  const _DownloadRow.spacer() : this._(_DownloadRowType.spacer);
  const _DownloadRow.error(String text)
      : this._(_DownloadRowType.error, text: text);

  final _DownloadRowType type;
  final DownloadedVideo? video;
  final String? text;
}

class _AudioProgressListTile extends StatefulWidget {
  final DownloadedVideo video;
  final VoidCallback onDelete;
  const _AudioProgressListTile({
    Key? key,
    required this.video,
    required this.onDelete,
  }) : super(key: key);

  @override
  State<_AudioProgressListTile> createState() => _AudioProgressListTileState();
}

class _AudioProgressListTileState extends State<_AudioProgressListTile> {
  double _progress = 0.0;
  int _durationMs = 0;
  StreamSubscription<Duration>? _positionSub;
  late VoidCallback _globalPlayingNotifierListener;
  static final Map<String, int> _durationCacheMs = {};

  @override
  void initState() {
    super.initState();
    _loadInitialProgress();
    _globalPlayingNotifierListener = () {
      _updateProgressAndListeningState();
    };
    DownloadService.globalPlayingNotifier.addListener(
      _globalPlayingNotifierListener,
    );
  }

  @override
  void didUpdateWidget(covariant _AudioProgressListTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.video.videoId != widget.video.videoId) {
      _positionSub?.cancel();
      _progress = 0.0;
      _durationMs = 0;
      _loadInitialProgress();
      _updateProgressAndListeningState();
    }
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    DownloadService.globalPlayingNotifier.removeListener(
      _globalPlayingNotifierListener,
    );
    super.dispose();
  }

  void _updateProgressAndListeningState() async {
    final playing = DownloadService.globalPlayingNotifier.value;
    final isThisAudioCurrentlyPlaying =
        (playing?.videoId == widget.video.videoId) &&
        (playing?.isPlaying ?? false);

    if (isThisAudioCurrentlyPlaying) {
      _positionSub?.cancel();
      _positionSub = DownloadService.globalAudioPlayer.positionStream.listen((
        pos,
      ) {
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
    final position =
        prefs.getInt('audio_position_${widget.video.videoId}') ?? 0;
    int duration = widget.video.duration?.inMilliseconds ?? 0;
    if (duration == 0) {
      duration = _durationCacheMs[widget.video.videoId] ?? 0;
      if (duration == 0) {
        try {
          final metadata = await MetadataRetriever.fromFile(
            File(widget.video.filePath),
          );
          duration = metadata.trackDuration ?? 0;
          if (duration > 0) {
            _durationCacheMs[widget.video.videoId] = duration;
          }
        } catch (_) {
          duration = 0;
        }
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
        final isPlayingThisAudio =
            (playing?.videoId == video.videoId) &&
            (playing?.isPlaying ?? false);
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
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(
                    video.thumbnailUrl,
                    width: 56,
                    height: 56,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => Container(
                      width: 56,
                      height: 56,
                      color: Colors.grey.shade300,
                      alignment: Alignment.center,
                      child: Icon(Icons.music_note, color: Colors.grey[600]),
                    ),
                  ),
                )
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
                    showGlobalSnackBar(
                      SnackBar(
                        content: Text(
                          'Audio file not found: ${video.filePath}',
                        ),
                      ),
                    );
                    return;
                  }
                  final current = DownloadService.globalPlayingNotifier.value;
                  final wasAlreadyLoaded =
                      current?.videoId == video.videoId &&
                      (current?.isLocal ?? false);
                  int lastPos = 0;
                  if (!wasAlreadyLoaded) {
                    final prefs = await SharedPreferences.getInstance();
                    lastPos =
                        prefs.getInt('audio_position_${video.videoId}') ?? 0;
                  }
                  await DownloadService.playOrPause(
                    video.videoId,
                    video.filePath,
                    title: video.title,
                    channelName: video.channelName,
                    thumbnailUrl: video.thumbnailUrl,
                  );
                  if (!wasAlreadyLoaded && lastPos > 0) {
                    await DownloadService.globalAudioPlayer.seek(
                      Duration(milliseconds: lastPos),
                    );
                  }
                },
              ),
              IconButton(icon: Icon(Icons.delete), onPressed: widget.onDelete),
            ],
          ),
          contentPadding: EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          onTap: () async {
            final file = File(video.filePath);
            if (!await file.exists()) {
              if (!mounted) return;
              showGlobalSnackBar(
                SnackBar(
                  content: Text('Audio file not found: ${video.filePath}'),
                ),
              );
              return;
            }
            final current = DownloadService.globalPlayingNotifier.value;
            final wasAlreadyLoaded =
                current?.videoId == video.videoId &&
                (current?.isLocal ?? false);
            int lastPos = 0;
            if (!wasAlreadyLoaded) {
              final prefs = await SharedPreferences.getInstance();
              lastPos = prefs.getInt('audio_position_${video.videoId}') ?? 0;
            }
            await DownloadService.playOrPause(
              video.videoId,
              video.filePath,
              title: video.title,
              channelName: video.channelName,
              thumbnailUrl: video.thumbnailUrl,
            );
            if (!wasAlreadyLoaded && lastPos > 0) {
              await DownloadService.globalAudioPlayer.seek(
                Duration(milliseconds: lastPos),
              );
            }
          },
        );
      },
    );
  }
}

@pragma('vm:entry-point')
Future<List<String>> _findOrphanedFilePaths(
  String directoryPath,
  List<String> dbPaths,
) async {
  final dbPathList = List<String>.from(dbPaths);
  return Isolate.run(() {
    final dbSet = dbPathList.toSet();
    final directory = Directory(directoryPath);
    if (!directory.existsSync()) return <String>[];
    final orphaned = directory
        .listSync(followLinks: false)
        .whereType<File>()
        .where((file) => file.path.endsWith('.mp3'))
        .map((file) => file.path)
        .where((path) => !dbSet.contains(path))
        .toList(growable: false);
    return orphaned;
  });
}
