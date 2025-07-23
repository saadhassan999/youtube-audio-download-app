import 'package:flutter/material.dart';
import '../models/downloaded_video.dart';
import '../services/database_service.dart';
import '../services/download_service.dart';
import 'audio_controls.dart';
import 'dart:io';

class AudioPlayerBottomSheet {
  static void show(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _AudioPlayerBottomSheetContent(),
    );
  }
}

class _AudioPlayerBottomSheetContent extends StatefulWidget {
  @override
  _AudioPlayerBottomSheetContentState createState() => _AudioPlayerBottomSheetContentState();
}

class _AudioPlayerBottomSheetContentState extends State<_AudioPlayerBottomSheetContent> {
  List<DownloadedVideo> _playlist = [];
  DownloadedVideo? _currentVideo;
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _loadPlaylist();
    _updateCurrentTrack();
  }

  Future<void> _loadPlaylist() async {
    final playlist = await DatabaseService.instance.getDownloadedVideos();
    setState(() {
      _playlist = playlist;
    });
    _updateCurrentTrack();
  }

  void _updateCurrentTrack() {
    final playing = DownloadService.globalPlayingNotifier.value;
    if (playing != null) {
      final index = _playlist.indexWhere((video) => video.videoId == playing.videoId);
      if (index != -1) {
        setState(() {
          _currentIndex = index;
          _currentVideo = _playlist[index];
        });
      }
    }
  }

  void _onTrackChanged(int newIndex) async {
    if (newIndex >= 0 && newIndex < _playlist.length) {
      final video = _playlist[newIndex];
      final file = File(video.filePath);
      
      if (await file.exists()) {
        await DownloadService.playOrPause(
          video.videoId,
          video.filePath,
          title: video.title,
          channelName: video.channelName,
          thumbnailUrl: video.thumbnailUrl,
        );
        
        setState(() {
          _currentIndex = newIndex;
          _currentVideo = video;
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Audio file not found: ${video.title}')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: true,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Container(
              margin: EdgeInsets.only(top: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Audio controls
            AudioControls(
              currentVideo: _currentVideo,
              playlist: _playlist,
              currentIndex: _currentIndex,
              onTrackChanged: _onTrackChanged,
            ),
          ],
        ),
      ),
    );
  }
} 