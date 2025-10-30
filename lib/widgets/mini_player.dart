import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';
import '../services/download_service.dart';
import 'audio_player_bottom_sheet.dart';
import 'dart:io' show FileSystemException;
import '../core/snackbar_bus.dart';

class MiniPlayer extends StatefulWidget {
  const MiniPlayer({super.key});

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer> {
  PlayingAudio? _current;

  @override
  void initState() {
    super.initState();
    _updatePlayerState();

    // Listen to player state changes
    DownloadService.globalPlayingNotifier.addListener(_updatePlayerState);
  }

  @override
  void dispose() {
    DownloadService.globalPlayingNotifier.removeListener(_updatePlayerState);
    super.dispose();
  }

  void _updatePlayerState() {
    if (!mounted) return;
    setState(() {
      _current = DownloadService.globalPlayingNotifier.value;
    });
  }

  void _playPause() async {
    if (_current == null) return;

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

  void _showFullPlayer() {
    AudioPlayerBottomSheet.show(context);
  }

  Future<void> _clearSession() async {
    await DownloadService.clearPlaybackSession();
    if (!mounted) return;
    setState(() {
      _current = null;
    });
  }

  Future<void> _seekRelative(Duration offset) async {
    final target = await DownloadService.seekRelative(offset);
    if (!mounted) return;
    if (target != null) {
      final direction = Directionality.of(context);
      final announcement = offset.isNegative
          ? 'Rewound to ${_formatDuration(target)}'
          : 'Forward to ${_formatDuration(target)}';
      SemanticsService.announce(announcement, direction);
    }
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    final hours = duration.inHours;
    if (hours > 0) {
      return '$hours:${twoDigits(minutes)}:${twoDigits(seconds)}';
    }
    return '${twoDigits(minutes)}:${twoDigits(seconds)}';
  }

  @override
  Widget build(BuildContext context) {
    // Don't show if nothing is playing
    final playing = _current;
    if (playing == null) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final textTheme = theme.textTheme;
    final thumbnailUrl = playing.thumbnailUrl ?? '';
    final title = playing.title ?? 'Now playing';
    final channelName = playing.channelName ?? '';
    final onSurfaceMuted = cs.onSurface.withOpacity(0.7);

    return SafeArea(
      top: false,
      child: Container(
        height: 64, // slightly reduced height
        decoration: BoxDecoration(
          color: cs.surface,
          boxShadow: [
            BoxShadow(
              color: theme.shadowColor.withOpacity(0.12),
              blurRadius: 8,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              // Thumbnail
              GestureDetector(
                onTap: _showFullPlayer,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: thumbnailUrl.isNotEmpty
                      ? Image.network(
                          thumbnailUrl,
                          width: 48,
                          height: 48,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) {
                            return Container(
                              width: 48,
                              height: 48,
                              color: cs.surfaceVariant,
                              child: Icon(
                                Icons.music_note,
                                color: cs.onSurfaceVariant,
                              ),
                            );
                          },
                        )
                      : Container(
                          width: 48,
                          height: 48,
                          color: cs.surfaceVariant,
                          child: Icon(
                            Icons.music_note,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                ),
              ),
              SizedBox(width: 8),
              // Track info
              Expanded(
              child: GestureDetector(
                onTap: _showFullPlayer,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: cs.onSurface,
                          ) ??
                          TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                            color: cs.onSurface,
                          ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    SizedBox(height: 2),
                    Text(
                      channelName,
                      style: textTheme.bodySmall?.copyWith(
                            color: onSurfaceMuted,
                            fontSize: 11,
                          ) ??
                          TextStyle(color: onSurfaceMuted, fontSize: 11),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
                ),
              ),
              // Control buttons
              StreamBuilder<Duration?>(
                stream: DownloadService.globalAudioPlayer.durationStream,
                builder: (context, durationSnapshot) {
                  final duration = durationSnapshot.data ?? Duration.zero;
                  return StreamBuilder<Duration>(
                    stream: DownloadService.globalAudioPlayer.positionStream,
                    builder: (context, positionSnapshot) {
                      final position = positionSnapshot.data ?? Duration.zero;
                      const epsilon = Duration(milliseconds: 300);
                      final canRewind = position > epsilon;
                      final canForward = duration > Duration.zero
                          ? (duration - position) > epsilon
                          : true;
                      final skipInterval = DownloadService.skipInterval;

                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Tooltip(
                            message: 'Rewind 10 seconds',
                            waitDuration: const Duration(milliseconds: 400),
                          child: IconButton(
                              onPressed: canRewind
                                  ? () => _seekRelative(-skipInterval)
                                  : null,
                              icon: const Icon(Icons.replay_10, size: 22),
                              color: canRewind
                                  ? cs.onSurface
                                  : cs.onSurface.withOpacity(0.4),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                            ),
                          ),
                          IconButton(
                            onPressed: _playPause,
                            icon: Icon(
                              playing.isPlaying
                                  ? Icons.pause
                                  : Icons.play_arrow,
                              size: 22,
                            ),
                            color: cs.primary,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                          Tooltip(
                            message: 'Forward 10 seconds',
                            waitDuration: const Duration(milliseconds: 400),
                            child: IconButton(
                              onPressed: canForward
                                  ? () => _seekRelative(skipInterval)
                                  : null,
                              icon: const Icon(Icons.forward_10, size: 22),
                              color: canForward
                                  ? cs.onSurface
                                  : cs.onSurface.withOpacity(0.4),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                            ),
                          ),
                          IconButton(
                            onPressed: _showFullPlayer,
                            icon: const Icon(Icons.expand_less, size: 22),
                            color: cs.onSurface,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                          IconButton(
                            onPressed: _clearSession,
                            icon: const Icon(Icons.close, size: 20),
                            color: cs.onSurface.withOpacity(0.5),
                            tooltip: 'Close player',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
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
      ),
    );
  }
}

class MiniPlayerHost extends StatelessWidget {
  const MiniPlayerHost({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: DownloadService.globalSessionActive,
      builder: (context, sessionActive, _) {
        return ValueListenableBuilder<PlayingAudio?>(
          valueListenable: DownloadService.globalPlayingNotifier,
          builder: (context, playing, __) {
            final show = DownloadService.shouldShowMiniPlayer(
              sessionActive: sessionActive,
              playing: playing,
            );
            return AnimatedSwitcher(
              duration: kThemeAnimationDuration,
              child: show
                  ? MiniPlayer(key: ValueKey(playing?.videoId ?? 'session'))
                  : const SizedBox.shrink(),
            );
          },
        );
      },
    );
  }
}
