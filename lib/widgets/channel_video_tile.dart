import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../core/snackbar_bus.dart';
import '../models/downloaded_video.dart';
import '../models/video.dart';
import '../services/database_service.dart';
import '../services/download_service.dart';

Future<void> playVideo(BuildContext context, Video video) async {
  final filePath = await DownloadService.getDownloadedFilePath(video.id);
  if (filePath != null) {
    final file = File(filePath);
    if (!await file.exists()) {
      showGlobalSnackBarMessage('Audio file not found: $filePath');
      DownloadService.downloadedVideosChanged.value++;
      return;
    }
    await DownloadService.playOrPause(
      video.id,
      filePath,
      title: video.title,
      channelName: video.channelName,
      thumbnailUrl: video.thumbnailUrl,
    );
    return;
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
    showGlobalSnackBar(SnackBar(content: Text('Failed to play audio: $e')));
  }
}

Future<void> downloadVideo(
  BuildContext context,
  Video video, {
  bool trackSavedVideo = false,
}) async {
  showGlobalSnackBarMessage('Download started: ${video.title}');
  try {
    final result = await DownloadService.downloadVideo(
      video,
      trackSavedVideo: trackSavedVideo,
    );
    bool cancelled = false;
    if (!trackSavedVideo) {
      cancelled = DownloadService.consumeCancelledFlag(video.id);
    }
    if (result != null) {
      showGlobalSnackBarMessage('Download complete: ${video.title}');
    } else if (cancelled) {
      showGlobalSnackBarMessage('Download cancelled: ${video.title}');
    } else {
      showGlobalSnackBarMessage('Download failed: ${video.title}');
    }
  } catch (e) {
    showGlobalSnackBar(SnackBar(content: Text('Download failed: $e')));
  }
}

class ChannelVideoTile extends StatefulWidget {
  const ChannelVideoTile({super.key, required this.video});

  final Video video;

  @override
  State<ChannelVideoTile> createState() => _ChannelVideoTileState();
}

class _ChannelVideoTileState extends State<ChannelVideoTile>
    with AutomaticKeepAliveClientMixin {
  DownloadedVideo? _downloadedVideo;
  bool _isManualDownloading = false;
  bool _isStreaming = false;
  bool _isRefreshingDownload = false;
  late final VoidCallback _downloadedListener;
  late final VoidCallback _playingListener;

  @override
  void initState() {
    super.initState();
    _downloadedListener = _refreshDownloadedVideo;
    DownloadService.downloadedVideosChanged.addListener(_downloadedListener);
    _playingListener = _handlePlayingUpdate;
    DownloadService.globalPlayingNotifier.addListener(_playingListener);
    _refreshDownloadedVideo();
  }

  @override
  void dispose() {
    DownloadService.globalPlayingNotifier.removeListener(_playingListener);
    DownloadService.downloadedVideosChanged.removeListener(_downloadedListener);
    super.dispose();
  }

  @override
  bool get wantKeepAlive => true;

  Future<void> _refreshDownloadedVideo() async {
    if (_isRefreshingDownload) return;
    _isRefreshingDownload = true;
    try {
      final record = await DatabaseService.instance.getDownloadedVideo(
        widget.video.id,
      );
      if (!mounted) return;
      setState(() {
        _downloadedVideo = record;
      });
    } finally {
      _isRefreshingDownload = false;
    }
  }

  void _handlePlayingUpdate() {
    if (!_isStreaming) return;
    final playing = DownloadService.globalPlayingNotifier.value;
    final isCurrentVideo = playing?.videoId == widget.video.id;
    if (!mounted) return;
    if (isCurrentVideo || playing != null) {
      setState(() {
        _isStreaming = false;
      });
    }
  }

  Future<void> _handlePlay() async {
    final video = widget.video;
    final current = DownloadService.globalPlayingNotifier.value;
    final isCurrent = current?.videoId == video.id;

    if (isCurrent) {
      try {
        await DownloadService.togglePlayback();
      } on FileSystemException {
        showGlobalSnackBarMessage(
          'Audio file not found. Stream or re-download to play.',
        );
        await DownloadService.clearPlaybackSession();
        await _refreshDownloadedVideo();
      } catch (e) {
        showGlobalSnackBarMessage('Playback error: $e');
      }
      return;
    }

    final localPath = await DownloadService.getDownloadedFilePath(video.id);
    final isLocal = localPath != null;

    if (!isLocal && mounted) {
      setState(() {
        _isStreaming = true;
      });
    }

    try {
      await playVideo(context, video);
    } finally {
      if (!isLocal && mounted) {
        setState(() {
          _isStreaming = false;
        });
      }
    }
  }

  Future<void> _startDownload() async {
    if (_isManualDownloading) return;
    final video = widget.video;
    setState(() {
      _isManualDownloading = true;
    });

    try {
      await downloadVideo(context, video);
    } finally {
      if (mounted) {
        setState(() {
          _isManualDownloading = false;
        });
      }
    }

    await _refreshDownloadedVideo();
  }

  Future<void> _cancelDownload() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel Download'),
        content: const Text('Are you sure you want to cancel this download?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('No'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Yes'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    await DownloadService.cancelDownload(widget.video.id);
    if (!mounted) return;
    setState(() {
      _isManualDownloading = false;
    });
    await _refreshDownloadedVideo();
    if (!mounted) return;
    showGlobalSnackBarMessage('Download cancelled');
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final video = widget.video;
    final downloaded = _downloadedVideo;
    final status = downloaded?.status ?? '';
    final isDownloaded = status == 'completed';
    final isDownloading = status == 'downloading' || _isManualDownloading;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final textTheme = theme.textTheme;
    final placeholderColor = cs.surfaceVariant;
    final onSurfaceMuted = cs.onSurface.withOpacity(0.7);

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
                    errorBuilder: (context, error, stackTrace) => Container(
                      width: 80,
                      height: 45,
                      color: placeholderColor,
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.image_not_supported,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  )
                : Container(
                    width: 80,
                    height: 45,
                    color: placeholderColor,
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.image,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  video.title,
                  style: textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface,
                      ) ??
                      TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                        color: cs.onSurface,
                      ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  'Published: ${video.published.toLocal().toString().split(' ')[0]}',
                  style: textTheme.bodySmall?.copyWith(
                        color: onSurfaceMuted,
                      ) ??
                      TextStyle(fontSize: 12, color: onSurfaceMuted),
                ),
                const SizedBox(height: 6),
                if (isDownloading)
                  ValueListenableBuilder<Map<String, double>>(
                    valueListenable: DownloadService.downloadProgressNotifier,
                    builder: (context, progressMap, _) {
                      final progress = progressMap[video.id];
                      final normalized = progress != null
                          ? progress.clamp(0.0, 1.0)
                          : null;
                      final progressText = normalized != null && normalized > 0
                          ? '${(normalized * 100).toStringAsFixed(0)}%'
                          : null;

                      return Row(
                        children: [
                          SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(
                              value: normalized != null && normalized > 0
                                  ? normalized
                                  : null,
                              strokeWidth: 2,
                              valueColor:
                                  AlwaysStoppedAnimation<Color>(cs.primary),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              progressText != null
                                  ? 'Download in progress ($progressText)'
                                  : 'Download in progress...',
                              style: const TextStyle(
                                fontSize: 12,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.close,
                              size: 20,
                              color: Colors.red,
                            ),
                            tooltip: 'Cancel Download',
                            onPressed: _cancelDownload,
                          ),
                        ],
                      );
                    },
                  )
                else
                  ValueListenableBuilder<PlayingAudio?>(
                    valueListenable: DownloadService.globalPlayingNotifier,
                    builder: (context, playing, _) {
                      final isSameVideo = playing?.videoId == video.id;
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
                          final playLabel = isLoading
                              ? 'Loading...'
                              : isPlaying
                              ? 'Pause'
                              : isSameVideo
                              ? 'Resume'
                              : isDownloaded
                              ? 'Play Offline'
                              : 'Play';
                          final playIcon = isPlaying
                              ? Icons.pause
                              : Icons.play_arrow;

                          final buttonTextStyle = textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          );

                          final playButton = FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: cs.primary,
                              foregroundColor: cs.onPrimary,
                              padding:
                                  const EdgeInsets.symmetric(vertical: 12),
                              textStyle: buttonTextStyle,
                            ),
                            onPressed: isLoading ? null : _handlePlay,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (isLoading)
                                  SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor: AlwaysStoppedAnimation(
                                        cs.onPrimary,
                                      ),
                                    ),
                                  )
                                else
                                  Icon(playIcon),
                                const SizedBox(width: 6),
                                Text(playLabel),
                              ],
                            ),
                          );

                          final downloadButton = OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: cs.onSurface,
                              side: BorderSide(color: cs.outline),
                              padding:
                                  const EdgeInsets.symmetric(vertical: 12),
                              textStyle: buttonTextStyle,
                            ),
                            onPressed: _startDownload,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.download, color: cs.onSurface),
                                const SizedBox(width: 6),
                                const Text('Download'),
                              ],
                            ),
                          );

                          return LayoutBuilder(
                            builder: (context, constraints) {
                              final isCompact = constraints.maxWidth < 360;
                              final showDownload = !isDownloaded;
                              if (!showDownload) {
                                return SizedBox(
                                  width: double.infinity,
                                  child: playButton,
                                );
                              }
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
  }
}
