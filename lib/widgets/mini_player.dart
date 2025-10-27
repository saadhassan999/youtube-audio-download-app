import 'package:flutter/material.dart';
import '../services/download_service.dart';
import 'audio_player_bottom_sheet.dart';
import 'dart:io';
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
    final playing = _current;
    if (playing == null) return;

    if (playing.isLocal) {
      final filePath = playing.filePath;
      if (filePath == null) {
        showGlobalSnackBarMessage('Audio file not found');
        return;
      }
      final file = File(filePath);
      if (!await file.exists()) {
        showGlobalSnackBarMessage('Audio file not found');
        return;
      }

      await DownloadService.playOrPause(
        playing.videoId,
        filePath,
        title: playing.title,
        channelName: playing.channelName,
        thumbnailUrl: playing.thumbnailUrl,
      );
    } else {
      await DownloadService.playStream(
        videoId: playing.videoId,
        videoUrl: 'https://www.youtube.com/watch?v=${playing.videoId}',
        title: playing.title,
        channelName: playing.channelName,
        thumbnailUrl: playing.thumbnailUrl,
      );
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

  @override
  Widget build(BuildContext context) {
    // Don't show if nothing is playing
    final playing = _current;
    if (playing == null) {
      return const SizedBox.shrink();
    }

    final thumbnailUrl = playing.thumbnailUrl ?? '';
    final title = playing.title ?? 'Now playing';
    final channelName = playing.channelName ?? '';

    return SafeArea(
      top: false,
      child: Container(
        height: 64, // slightly reduced height
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          boxShadow: [
            BoxShadow(
              color: Colors.black12,
              blurRadius: 8,
              offset: Offset(0, -2),
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
                              color: Colors.grey[300],
                              child: Icon(
                                Icons.music_note,
                                color: Colors.grey[600],
                              ),
                            );
                          },
                        )
                      : Container(
                          width: 48,
                          height: 48,
                          color: Colors.grey[300],
                          child: Icon(
                            Icons.music_note,
                            color: Colors.grey[600],
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
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      SizedBox(height: 2),
                      Text(
                        channelName,
                        style: TextStyle(color: Colors.grey[600], fontSize: 11),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ),
              // Control buttons
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    onPressed: _playPause,
                    icon: Icon(
                      playing.isPlaying ? Icons.pause : Icons.play_arrow,
                      size: 22,
                    ),
                    color: Theme.of(context).primaryColor,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                  IconButton(
                    onPressed: _showFullPlayer,
                    icon: const Icon(Icons.expand_less, size: 22),
                    color: Colors.grey[600],
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                  IconButton(
                    onPressed: _clearSession,
                    icon: const Icon(Icons.close, size: 20),
                    color: Colors.grey[500],
                    tooltip: 'Close player',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
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
