import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/snackbar_bus.dart';
import '../models/downloaded_video.dart';
import '../services/download_service.dart';
import 'audio_controls.dart';

class AudioPlayerBottomSheet {
  static void show(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      showDragHandle: false,
      builder: (context) => _AudioPlayerBottomSheetContent(),
    );
  }
}

class _AudioPlayerBottomSheetContent extends StatefulWidget {
  @override
  _AudioPlayerBottomSheetContentState createState() =>
      _AudioPlayerBottomSheetContentState();
}

class _AudioPlayerBottomSheetContentState
    extends State<_AudioPlayerBottomSheetContent> {
  List<DownloadedVideo> _playlist = [];
  int _currentIndex = -1;
  late final VoidCallback _playingListener;
  late final VoidCallback _downloadsListener;

  @override
  void initState() {
    super.initState();
    _playingListener = _syncWithCurrentlyPlaying;
    DownloadService.globalPlayingNotifier.addListener(_playingListener);
    _downloadsListener = () {
      unawaited(_loadPlaylist(forceRefresh: true));
    };
    DownloadService.downloadedVideosChanged.addListener(_downloadsListener);
    unawaited(_loadPlaylist());
    _syncWithCurrentlyPlaying();
  }

  @override
  void dispose() {
    DownloadService.downloadedVideosChanged.removeListener(_downloadsListener);
    DownloadService.globalPlayingNotifier.removeListener(_playingListener);
    super.dispose();
  }

  Future<void> _loadPlaylist({bool forceRefresh = false}) async {
    final playlist = await DownloadService.buildDownloadedQueueFromDb(
      forceRefresh: forceRefresh,
    );
    if (!mounted) return;
    final playing = DownloadService.globalPlayingNotifier.value;
    final index = playing == null
        ? -1
        : playlist.indexWhere((video) => video.videoId == playing.videoId);
    setState(() {
      _playlist = playlist;
      _currentIndex = index;
    });
  }

  void _syncWithCurrentlyPlaying() {
    if (!mounted) return;
    final playing = DownloadService.globalPlayingNotifier.value;
    final index = playing == null
        ? -1
        : _playlist.indexWhere((video) => video.videoId == playing.videoId);
    if (index != _currentIndex) {
      setState(() {
        _currentIndex = index;
      });
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
        });
      } else {
        showGlobalSnackBarMessage('Audio file not found: ${video.title}');
        await DownloadService.clearPlaybackSession();
        setState(() {
          _currentIndex = -1;
        });
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
            ValueListenableBuilder<PlayingAudio?>(
              valueListenable: DownloadService.globalPlayingNotifier,
              builder: (context, playing, _) {
                return AudioControls(
                  playlist: _playlist,
                  currentIndex: _currentIndex,
                  onTrackChanged: _onTrackChanged,
                  playing: playing,
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
