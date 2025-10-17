import 'package:flutter/material.dart';
import '../services/download_service.dart';
import '../services/database_service.dart';
import '../models/downloaded_video.dart';
import 'audio_player_bottom_sheet.dart';
import 'dart:io';
import '../core/snackbar_bus.dart';

class MiniPlayer extends StatefulWidget {
  @override
  _MiniPlayerState createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer> {
  DownloadedVideo? _currentVideo;
  bool _isPlaying = false;

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

  void _updatePlayerState() async {
    final playing = DownloadService.globalPlayingNotifier.value;
    if (playing != null && playing.isPlaying) {
      // Get the current video info
      final video = await DatabaseService.instance.getDownloadedVideo(
        playing.videoId,
      );
      setState(() {
        _currentVideo = video;
        _isPlaying = playing.isPlaying;
      });
    } else {
      setState(() {
        _isPlaying = false;
      });
    }
  }

  void _playPause() async {
    if (_currentVideo == null) return;

    final file = File(_currentVideo!.filePath);
    if (!await file.exists()) {
      showGlobalSnackBarMessage('Audio file not found');
      return;
    }

    await DownloadService.playOrPause(
      _currentVideo!.videoId,
      _currentVideo!.filePath,
      title: _currentVideo!.title,
      channelName: _currentVideo!.channelName,
      thumbnailUrl: _currentVideo!.thumbnailUrl,
    );
  }

  void _showFullPlayer() {
    AudioPlayerBottomSheet.show(context);
  }

  @override
  Widget build(BuildContext context) {
    // Don't show if nothing is playing
    if (_currentVideo == null || !_isPlaying) {
      return SizedBox.shrink();
    }

    return SafeArea(
      minimum: EdgeInsets.only(bottom: 0),
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
                  child: _currentVideo!.thumbnailUrl.isNotEmpty
                      ? Image.network(
                          _currentVideo!.thumbnailUrl,
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
                        _currentVideo!.title,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      SizedBox(height: 2),
                      Text(
                        _currentVideo!.channelName,
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
                      _isPlaying ? Icons.pause : Icons.play_arrow,
                      size: 22,
                    ),
                    color: Theme.of(context).primaryColor,
                    padding: EdgeInsets.zero,
                    constraints: BoxConstraints(),
                  ),
                  IconButton(
                    onPressed: _showFullPlayer,
                    icon: Icon(Icons.skip_next, size: 22),
                    color: Colors.grey[600],
                    padding: EdgeInsets.zero,
                    constraints: BoxConstraints(),
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
