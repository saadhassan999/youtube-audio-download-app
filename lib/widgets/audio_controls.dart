import 'package:flutter/material.dart';
import 'package:just_audio_background/just_audio_background.dart';
import '../services/download_service.dart';
import '../models/downloaded_video.dart';
import 'dart:io';
import '../core/snackbar_bus.dart';

class AudioControls extends StatefulWidget {
  final DownloadedVideo? currentVideo;
  final List<DownloadedVideo> playlist;
  final int currentIndex;
  final Function(int) onTrackChanged;

  const AudioControls({
    Key? key,
    this.currentVideo,
    required this.playlist,
    required this.currentIndex,
    required this.onTrackChanged,
  }) : super(key: key);

  @override
  _AudioControlsState createState() => _AudioControlsState();
}

class _AudioControlsState extends State<AudioControls> {
  bool _isDragging = false;
  double _dragValue = 0.0;
  double _playbackSpeed = 1.0;
  bool _showSpeedOptions = false;

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

  void _playPause() async {
    if (widget.currentVideo == null) return;

    final file = File(widget.currentVideo!.filePath);
    if (!await file.exists()) {
      showGlobalSnackBarMessage('Audio file not found');
      return;
    }

    await DownloadService.playOrPause(
      widget.currentVideo!.videoId,
      widget.currentVideo!.filePath,
      title: widget.currentVideo!.title,
      channelName: widget.currentVideo!.channelName,
      thumbnailUrl: widget.currentVideo!.thumbnailUrl,
    );
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

  void _setPlaybackSpeed(double speed) async {
    await DownloadService.globalAudioPlayer.setSpeed(speed);
    setState(() {
      _playbackSpeed = speed;
      _showSpeedOptions = false;
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
    return Container(
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
          if (widget.currentVideo != null) ...[
            Row(
              children: [
                // Thumbnail
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: widget.currentVideo!.thumbnailUrl.isNotEmpty
                      ? Image.network(
                          widget.currentVideo!.thumbnailUrl,
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
                        widget.currentVideo!.title,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      SizedBox(height: 4),
                      Text(
                        widget.currentVideo!.channelName,
                        style: TextStyle(color: Colors.grey[600], fontSize: 14),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                // Speed control
                PopupMenuButton<double>(
                  icon: Container(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.grey[200],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${_playbackSpeed.toStringAsFixed(1)}x',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  itemBuilder: (context) => [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
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

                  return Column(
                    children: [
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          activeTrackColor: Theme.of(context).primaryColor,
                          inactiveTrackColor: Colors.grey[300],
                          thumbColor: Theme.of(context).primaryColor,
                          thumbShape: RoundSliderThumbShape(
                            enabledThumbRadius: 6,
                          ),
                          trackHeight: 4,
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
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _formatDuration(position),
                              style: TextStyle(
                                color: Colors.grey[600],
                                fontSize: 12,
                              ),
                            ),
                            Text(
                              _formatDuration(duration),
                              style: TextStyle(
                                color: Colors.grey[600],
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
          SizedBox(height: 16),

          // Control buttons
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // Previous button
              IconButton(
                onPressed: widget.currentIndex > 0 ? _skipToPrevious : null,
                icon: Icon(Icons.skip_previous, size: 32),
                color: widget.currentIndex > 0 ? null : Colors.grey[400],
              ),

              // Play/Pause button
              ValueListenableBuilder<PlayingAudio?>(
                valueListenable: DownloadService.globalPlayingNotifier,
                builder: (context, playing, _) {
                  final isPlaying = playing?.isPlaying ?? false;
                  final isCurrentTrack =
                      playing?.videoId == widget.currentVideo?.videoId;

                  return Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).primaryColor,
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      onPressed: _playPause,
                      icon: Icon(
                        (isPlaying && isCurrentTrack)
                            ? Icons.pause
                            : Icons.play_arrow,
                        size: 32,
                        color: Colors.white,
                      ),
                    ),
                  );
                },
              ),

              // Next button
              IconButton(
                onPressed: widget.currentIndex < widget.playlist.length - 1
                    ? _skipToNext
                    : null,
                icon: Icon(Icons.skip_next, size: 32),
                color: widget.currentIndex < widget.playlist.length - 1
                    ? null
                    : Colors.grey[400],
              ),
            ],
          ),
          SizedBox(height: 8),

          // Playlist info
          if (widget.playlist.isNotEmpty) ...[
            Container(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '${widget.currentIndex + 1} of ${widget.playlist.length}',
                style: TextStyle(
                  color: Colors.grey[600],
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],

          SizedBox(height: 16),
        ],
      ),
    );
  }
}
