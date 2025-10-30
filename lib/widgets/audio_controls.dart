import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';
import 'package:just_audio/just_audio.dart';
import '../services/download_service.dart';
import '../models/downloaded_video.dart';
import 'dart:io' show FileSystemException;
import '../core/snackbar_bus.dart';

class AudioControls extends StatefulWidget {
  final List<DownloadedVideo> playlist;
  final int currentIndex;
  final Function(int) onTrackChanged;
  final PlayingAudio? playing;

  const AudioControls({
    Key? key,
    required this.playlist,
    required this.currentIndex,
    required this.onTrackChanged,
    this.playing,
  }) : super(key: key);

  @override
  _AudioControlsState createState() => _AudioControlsState();
}

class _RelativeSeekIntent extends Intent {
  const _RelativeSeekIntent(this.offset);
  final Duration offset;
}

class _SpeedChip extends StatelessWidget {
  const _SpeedChip({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: cs.primaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        label,
        style:
            theme.textTheme.labelLarge?.copyWith(
              color: cs.onPrimaryContainer,
              fontWeight: FontWeight.w600,
            ) ??
            TextStyle(
              color: cs.onPrimaryContainer,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

class _QueuePositionPill extends StatelessWidget {
  const _QueuePositionPill({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: cs.secondaryContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        label,
        style:
            theme.textTheme.labelLarge?.copyWith(
              color: cs.onSecondaryContainer,
              fontWeight: FontWeight.w600,
            ) ??
            TextStyle(
              color: cs.onSecondaryContainer,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

class _AudioControlsState extends State<AudioControls> {
  bool _isDragging = false;
  double _dragValue = 0.0;
  double _playbackSpeed = 1.0;

  @override
  void initState() {
    super.initState();
    // Initialize playback speed
    DownloadService.globalAudioPlayer.speedStream.listen((speed) {
      if (mounted) {
        setState(() {
          _playbackSpeed = speed;
        });
      }
    });
  }

  Future<void> _playPause() async {
    if (widget.playing == null) return;

    try {
      await DownloadService.togglePlayback();
    } on FileSystemException {
      showGlobalSnackBarMessage(
        'File not found. Stream or re-download to play.',
      );
    } catch (e) {
      showGlobalSnackBarMessage('Playback error: $e');
    }
  }

  void _skipToPrevious() {
    if (widget.currentIndex > 0) {
      widget.onTrackChanged(widget.currentIndex - 1);
    }
  }

  void _skipToNext() {
    if (widget.currentIndex < widget.playlist.length - 1) {
      widget.onTrackChanged(widget.currentIndex + 1);
    }
  }

  void _seekToPosition(double value) async {
    final duration = DownloadService.globalAudioPlayer.duration;
    if (duration != null) {
      final position = Duration(seconds: (value * duration.inSeconds).round());
      await DownloadService.globalAudioPlayer.seek(position);
    }
  }

  Future<void> _seekRelative(Duration offset) async {
    final target = await DownloadService.seekRelative(offset);
    if (!mounted) return;
    if (target != null) {
      final direction = Directionality.of(context);
      final msg = offset.isNegative
          ? 'Rewound to ${_formatDuration(target)}'
          : 'Forward to ${_formatDuration(target)}';
      SemanticsService.announce(msg, direction);
    }
  }

  void _setPlaybackSpeed(double speed) async {
    await DownloadService.globalAudioPlayer.setSpeed(speed);
    setState(() {
      _playbackSpeed = speed;
    });
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '$hours:${twoDigits(minutes)}:${twoDigits(seconds)}';
    } else {
      return '${twoDigits(minutes)}:${twoDigits(seconds)}';
    }
  }

  @override
  Widget build(BuildContext context) {
    final shortcuts = <LogicalKeySet, Intent>{
      LogicalKeySet(LogicalKeyboardKey.arrowLeft): const _RelativeSeekIntent(
        Duration(seconds: -10),
      ),
      LogicalKeySet(LogicalKeyboardKey.arrowRight): const _RelativeSeekIntent(
        Duration(seconds: 10),
      ),
    };
    final playing = widget.playing;
    final playlistVideo =
        (widget.currentIndex >= 0 &&
            widget.currentIndex < widget.playlist.length)
        ? widget.playlist[widget.currentIndex]
        : null;
    final thumbnailUrl = () {
      final fromPlaying = playing?.thumbnailUrl;
      if (fromPlaying != null && fromPlaying.isNotEmpty) {
        return fromPlaying;
      }
      final fromPlaylist = playlistVideo?.thumbnailUrl;
      if (fromPlaylist != null && fromPlaylist.isNotEmpty) {
        return fromPlaylist;
      }
      return '';
    }();
    final trackTitle = playing?.title ?? playlistVideo?.title ?? 'Now playing';
    final trackChannel =
        playing?.channelName ?? playlistVideo?.channelName ?? '';

    return Shortcuts(
      shortcuts: shortcuts,
      child: Actions(
        actions: <Type, Action<Intent>>{
          _RelativeSeekIntent: CallbackAction<_RelativeSeekIntent>(
            onInvoke: (intent) {
              _seekRelative(intent.offset);
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Container(
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black12,
                  blurRadius: 10,
                  offset: Offset(0, -2),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Handle bar
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                SizedBox(height: 16),

                // Track info
                if (playing != null || playlistVideo != null) ...[
                  Row(
                    children: [
                      // Thumbnail
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: thumbnailUrl.isNotEmpty
                            ? Image.network(
                                thumbnailUrl,
                                width: 60,
                                height: 60,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) {
                                  return Container(
                                    width: 60,
                                    height: 60,
                                    color: Colors.grey[300],
                                    child: Icon(
                                      Icons.music_note,
                                      color: Colors.grey[600],
                                    ),
                                  );
                                },
                              )
                            : Container(
                                width: 60,
                                height: 60,
                                color: Colors.grey[300],
                                child: Icon(
                                  Icons.music_note,
                                  color: Colors.grey[600],
                                ),
                              ),
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              trackTitle,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 16,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            SizedBox(height: 4),
                            Text(
                              trackChannel,
                              style: TextStyle(
                                color: Colors.grey[600],
                                fontSize: 14,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      // Speed control
                      PopupMenuButton<double>(
                        icon: _SpeedChip(
                          label: '${_playbackSpeed.toStringAsFixed(1)}x',
                        ),
                        itemBuilder: (context) =>
                            [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
                                .map(
                                  (speed) => PopupMenuItem(
                                    value: speed,
                                    child: Text('${speed.toStringAsFixed(1)}x'),
                                  ),
                                )
                                .toList(),
                        onSelected: _setPlaybackSpeed,
                      ),
                    ],
                  ),
                  SizedBox(height: 16),
                ],

                // Progress bar
                StreamBuilder<Duration?>(
                  stream: DownloadService.globalAudioPlayer.durationStream,
                  builder: (context, durationSnapshot) {
                    final duration = durationSnapshot.data ?? Duration.zero;
                    return StreamBuilder<Duration>(
                      stream: DownloadService.globalAudioPlayer.positionStream,
                      builder: (context, positionSnapshot) {
                        final position = positionSnapshot.data ?? Duration.zero;
                        final progress = duration.inSeconds > 0
                            ? position.inSeconds / duration.inSeconds
                            : 0.0;
                        const epsilon = Duration(milliseconds: 300);
                        final canRewind = position > epsilon;
                        final canForward = duration > Duration.zero
                            ? (duration - position) > epsilon
                            : true;
                        final skipInterval = DownloadService.skipInterval;

                        return Column(
                          children: [
                            SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 4,
                                activeTrackColor: Theme.of(
                                  context,
                                ).colorScheme.primary,
                                inactiveTrackColor: Theme.of(
                                  context,
                                ).colorScheme.outlineVariant,
                                thumbColor: Theme.of(
                                  context,
                                ).colorScheme.primary,
                                overlayColor: Theme.of(
                                  context,
                                ).colorScheme.primary.withOpacity(0.12),
                                thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 6,
                                ),
                              ),
                              child: Slider(
                                value: _isDragging ? _dragValue : progress,
                                onChanged: (value) {
                                  setState(() {
                                    _isDragging = true;
                                    _dragValue = value;
                                  });
                                },
                                onChangeEnd: (value) {
                                  setState(() {
                                    _isDragging = false;
                                  });
                                  _seekToPosition(value);
                                },
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    _formatDuration(position),
                                    style:
                                        Theme.of(
                                          context,
                                        ).textTheme.bodySmall?.copyWith(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withOpacity(0.7),
                                        ) ??
                                        TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withOpacity(0.7),
                                          fontSize: 12,
                                        ),
                                  ),
                                  Text(
                                    _formatDuration(duration),
                                    style:
                                        Theme.of(
                                          context,
                                        ).textTheme.bodySmall?.copyWith(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withOpacity(0.7),
                                        ) ??
                                        TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withOpacity(0.7),
                                          fontSize: 12,
                                        ),
                                  ),
                                ],
                              ),
                            ),
                            SizedBox(height: 16),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                // Previous track
                                IconButton(
                                  onPressed: widget.currentIndex > 0
                                      ? _skipToPrevious
                                      : null,
                                  icon: const Icon(
                                    Icons.skip_previous,
                                    size: 32,
                                  ),
                                  color: widget.currentIndex > 0
                                      ? Theme.of(context).colorScheme.onSurface
                                      : Theme.of(context).colorScheme.onSurface
                                            .withOpacity(0.4),
                                ),
                                Tooltip(
                                  message: 'Rewind 10 seconds',
                                  waitDuration: const Duration(
                                    milliseconds: 400,
                                  ),
                                  child: IconButton(
                                    onPressed: canRewind
                                        ? () => _seekRelative(-skipInterval)
                                        : null,
                                    icon: const Icon(Icons.replay_10, size: 32),
                                    color: canRewind
                                        ? Theme.of(
                                            context,
                                          ).colorScheme.onSurface
                                        : Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withOpacity(0.4),
                                  ),
                                ),
                                // Play/Pause
                                StreamBuilder<PlayerState>(
                                  stream: DownloadService
                                      .globalAudioPlayer
                                      .playerStateStream,
                                  builder: (context, snapshot) {
                                    final state = snapshot.data;
                                    final processingState =
                                        state?.processingState ??
                                        ProcessingState.idle;
                                    final isBuffering =
                                        processingState ==
                                            ProcessingState.loading ||
                                        processingState ==
                                            ProcessingState.buffering;
                                    final isPlaying = state?.playing ?? false;
                                    final showPause =
                                        isPlaying &&
                                        processingState !=
                                            ProcessingState.completed &&
                                        processingState != ProcessingState.idle;
                                    final isDisabled =
                                        playing == null || isBuffering;
                                    final icon = showPause
                                        ? Icons.pause
                                        : Icons.play_arrow;

                                    final cs = Theme.of(context).colorScheme;
                                    return Container(
                                      decoration: BoxDecoration(
                                        color: cs.primary,
                                        shape: BoxShape.circle,
                                      ),
                                      child: IconButton(
                                        onPressed: isDisabled
                                            ? null
                                            : _playPause,
                                        icon: isBuffering
                                            ? SizedBox(
                                                width: 24,
                                                height: 24,
                                                child: CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                  valueColor:
                                                      AlwaysStoppedAnimation<
                                                        Color
                                                      >(cs.onPrimary),
                                                ),
                                              )
                                            : Icon(
                                                icon,
                                                size: 32,
                                                color: cs.onPrimary,
                                              ),
                                      ),
                                    );
                                  },
                                ),
                                Tooltip(
                                  message: 'Forward 10 seconds',
                                  waitDuration: const Duration(
                                    milliseconds: 400,
                                  ),
                                  child: IconButton(
                                    onPressed: canForward
                                        ? () => _seekRelative(skipInterval)
                                        : null,
                                    icon: const Icon(
                                      Icons.forward_10,
                                      size: 32,
                                    ),
                                    color: canForward
                                        ? Theme.of(
                                            context,
                                          ).colorScheme.onSurface
                                        : Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withOpacity(0.4),
                                  ),
                                ),
                                // Next track
                                IconButton(
                                  onPressed:
                                      widget.currentIndex <
                                          widget.playlist.length - 1
                                      ? _skipToNext
                                      : null,
                                  icon: const Icon(Icons.skip_next, size: 32),
                                  color:
                                      widget.currentIndex <
                                          widget.playlist.length - 1
                                      ? Theme.of(context).colorScheme.onSurface
                                      : Theme.of(context).colorScheme.onSurface
                                            .withOpacity(0.4),
                                ),
                              ],
                            ),
                          ],
                        );
                      },
                    );
                  },
                ),
                SizedBox(height: 8),

                // Playlist info
                if (widget.playlist.isNotEmpty && widget.currentIndex >= 0) ...[
                  _QueuePositionPill(
                    label:
                        '${widget.currentIndex + 1} of ${widget.playlist.length}',
                  ),
                ],

                SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
