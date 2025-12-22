import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';
import 'package:just_audio/just_audio.dart';
import '../models/audio_file.dart';
import '../services/database_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/download_service.dart';

class AudioPlayerScreen extends StatefulWidget {
  const AudioPlayerScreen({super.key});

  @override
  _AudioPlayerScreenState createState() => _AudioPlayerScreenState();
}

class _ScreenSeekIntent extends Intent {
  const _ScreenSeekIntent(this.offset);
  final Duration offset;
}

class _AudioPlayerScreenState extends State<AudioPlayerScreen>
    with WidgetsBindingObserver {
  // Use the global player
  final AudioPlayer _player = DownloadService.globalAudioPlayer;
  double _speed = 1.0;
  bool _isPlaying = false;
  AudioFile? _audioFile;
  List<AudioFile> _playlist = [];
  int _currentIndex = 0;
  bool _restoredPosition = false;
  static const String _lastAudioIdKey = 'last_audio_id';
  static const String _lastAudioPositionKey = 'last_audio_position';
  static const String _lastAudioStateKey = 'last_audio_state';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _restoreLastSession();
    _player.playerStateStream.listen((state) {
      setState(() {
        _isPlaying = state.playing;
      });
      _savePlaybackState();
      // Save position and state when playback is stopped or completed
      if (state.processingState == ProcessingState.completed ||
          state.processingState == ProcessingState.idle) {
        if (_audioFile != null && _audioFile!.id != null) {
          _savePlaybackPosition(_audioFile!.id!, _player.position);
          _savePlaybackState();
        }
      }
    });
    // Save position periodically
    _player.positionStream.listen((pos) {
      if (_audioFile != null && _restoredPosition && _audioFile!.id != null) {
        _savePlaybackPosition(_audioFile!.id!, pos);
        _savePlaybackState();
      }
    });
  }

  Future<void> _restoreLastSession() async {
    final prefs = await SharedPreferences.getInstance();
    final lastId = prefs.getInt(_lastAudioIdKey);
    final lastPos = prefs.getInt(_lastAudioPositionKey);
    final lastState = prefs.getString(_lastAudioStateKey);
    if (lastId != null) {
      _playlist = await DatabaseService.instance.getAudioFiles();
      AudioFile? lastAudio;
      if (_playlist.isNotEmpty) {
        lastAudio = _playlist.firstWhere(
          (a) => a.id == lastId,
          orElse: () => _playlist[0],
        );
      } else {
        lastAudio = null;
      }
      if (lastAudio != null) {
        _audioFile = lastAudio;
        _currentIndex = _playlist.indexWhere((a) => a.id == _audioFile!.id);
        await _setAudioSource(_audioFile!);
        if (lastPos != null && lastPos > 0) {
          await _player.seek(Duration(milliseconds: lastPos));
        }
        _restoredPosition = true;
        setState(() {});
        if (lastState == 'playing') {
          _play();
        }
      }
    } else {
      _initPlayer();
    }
  }

  Future<void> _initPlayer() async {
    final args = ModalRoute.of(context)!.settings.arguments;
    if (args is AudioFile) {
      _audioFile = args;
      _playlist = await DatabaseService.instance.getAudioFiles();
      _currentIndex = _playlist.indexWhere((a) => a.id == _audioFile!.id);
      await _setAudioSource(_audioFile!);
      if (_audioFile!.id != null) {
        await _restorePlaybackPosition(_audioFile!.id!);
      }
      setState(() {});
    }
  }

  Future<void> _setAudioSource(AudioFile audioFile) async {
    // Use DownloadService.playOrPause to ensure MediaItem is set and notification is updated
    await DownloadService.playOrPause(
      audioFile.videoId ?? audioFile.id.toString(),
      audioFile.filePath,
      title: audioFile.title,
      channelName: audioFile.channelName,
      thumbnailUrl: audioFile.thumbnailUrl,
    );
  }

  Future<void> _savePlaybackPosition(int audioId, Duration position) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('audio_position_$audioId', position.inMilliseconds);
    await prefs.setInt(_lastAudioIdKey, audioId);
    await prefs.setInt(_lastAudioPositionKey, position.inMilliseconds);
  }

  Future<void> _restorePlaybackPosition(int audioId) async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt('audio_position_$audioId');
    if (ms != null && ms > 0) {
      await _player.seek(Duration(milliseconds: ms));
    }
    _restoredPosition = true;
  }

  Future<void> _savePlaybackState() async {
    final prefs = await SharedPreferences.getInstance();
    if (_audioFile != null && _audioFile!.id != null) {
      await prefs.setInt(_lastAudioIdKey, _audioFile!.id!);
      await prefs.setInt(
        _lastAudioPositionKey,
        _player.position.inMilliseconds,
      );
      await prefs.setString(
        _lastAudioStateKey,
        _isPlaying ? 'playing' : 'paused',
      );
    }
  }

  void _play() => _player.play();
  void _pause() => _player.pause();
  void _seek(Duration pos) => _player.seek(pos);
  void _setSpeed(double speed) {
    _player.setSpeed(speed);
    setState(() => _speed = speed);
  }

  void _skip(int offset) async {
    int newIndex = _currentIndex + offset;
    if (newIndex >= 0 && newIndex < _playlist.length) {
      _currentIndex = newIndex;
      _audioFile = _playlist[_currentIndex];
      await _setAudioSource(_audioFile!);
      if (_audioFile!.id != null) {
        await _restorePlaybackPosition(_audioFile!.id!);
      }
      _play();
      setState(() {});
      await _savePlaybackState();
    }
  }

  Future<void> _seekRelative(Duration offset) async {
    final target = await DownloadService.seekRelative(offset);
    if (!mounted) return;
    if (target != null) {
      final direction = Directionality.of(context);
      final message = offset.isNegative
          ? 'Rewound to ${_formatDuration(target)}'
          : 'Forward to ${_formatDuration(target)}';
      SemanticsService.announce(message, direction);
    }
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '$hours:${twoDigits(minutes)}:${twoDigits(seconds)}';
    }
    return '${twoDigits(minutes)}:${twoDigits(seconds)}';
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_audioFile != null && _audioFile!.id != null) {
      if (state == AppLifecycleState.paused ||
          state == AppLifecycleState.inactive ||
          state == AppLifecycleState.detached) {
        _savePlaybackPosition(_audioFile!.id!, _player.position);
        _savePlaybackState();
      }
    }
    super.didChangeAppLifecycleState(state);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_audioFile != null && _audioFile!.id != null) {
      _savePlaybackPosition(_audioFile!.id!, _player.position);
      _savePlaybackState();
    }
    // Do not dispose the global player here!
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_audioFile == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final shortcuts = <LogicalKeySet, Intent>{
      LogicalKeySet(LogicalKeyboardKey.arrowLeft): const _ScreenSeekIntent(
        Duration(seconds: -10),
      ),
      LogicalKeySet(LogicalKeyboardKey.arrowRight): const _ScreenSeekIntent(
        Duration(seconds: 10),
      ),
    };

    return Shortcuts(
      shortcuts: shortcuts,
      child: Actions(
        actions: <Type, Action<Intent>>{
          _ScreenSeekIntent: CallbackAction<_ScreenSeekIntent>(
            onInvoke: (intent) {
              _seekRelative(intent.offset);
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            appBar: AppBar(
              title: Text(
                _audioFile!.title,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
              backgroundColor: Theme.of(context).colorScheme.surface,
              foregroundColor: Theme.of(context).colorScheme.onSurface,
            ),
            body: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    _audioFile!.channelName,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 16),
                  StreamBuilder<Duration?>(
                    stream: _player.durationStream,
                    builder: (context, snapshot) {
                      final duration = snapshot.data ?? Duration.zero;
                      return StreamBuilder<Duration>(
                        stream: _player.positionStream,
                        builder: (context, posSnap) {
                          final pos = posSnap.data ?? Duration.zero;
                          final durationMs = duration.inMilliseconds;
                          final posMs = pos.inMilliseconds;
                          double sliderMax = durationMs > 0
                              ? durationMs.toDouble()
                              : (posMs + 1000).toDouble();
                          if (sliderMax <= 0) sliderMax = 1;
                          final sliderValue = posMs.toDouble().clamp(
                            0.0,
                            sliderMax,
                          );
                          return Column(
                            children: [
                              Slider(
                                value: sliderValue,
                                min: 0,
                                max: sliderMax,
                                onChanged: (v) =>
                                    _seek(Duration(milliseconds: v.round())),
                              ),
                              Text(
                                '${_formatDuration(pos)} / ${_formatDuration(duration)}',
                              ),
                            ],
                          );
                        },
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  StreamBuilder<Duration?>(
                    stream: _player.durationStream,
                    builder: (context, durationSnapshot) {
                      final duration = durationSnapshot.data ?? Duration.zero;
                      return StreamBuilder<PlayerState>(
                        stream: _player.playerStateStream,
                        builder: (context, stateSnapshot) {
                          final playerState =
                              stateSnapshot.data ?? _player.playerState;
                          return StreamBuilder<Duration>(
                            stream: _player.positionStream,
                            builder: (context, posSnapshot) {
                              final pos = posSnapshot.data ?? Duration.zero;
                              const epsilon = Duration(milliseconds: 300);
                              final canRewind = pos > epsilon;
                              final canForward = duration > Duration.zero
                                  ? (duration - pos) > epsilon
                                  : true;
                              final skipInterval = DownloadService.skipInterval;
                              final isPlayingState = playerState.playing;
                              return Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.skip_previous),
                                    onPressed: () => _skip(-1),
                                  ),
                                  Tooltip(
                                    message: 'Rewind 10 seconds',
                                    waitDuration: const Duration(
                                      milliseconds: 400,
                                    ),
                                    child: IconButton(
                                      icon: const Icon(Icons.replay_10),
                                      onPressed: canRewind
                                          ? () => _seekRelative(-skipInterval)
                                          : null,
                                    ),
                                  ),
                                  IconButton(
                                    icon: Icon(
                                      isPlayingState
                                          ? Icons.pause
                                          : Icons.play_arrow,
                                    ),
                                    onPressed: isPlayingState ? _pause : _play,
                                    iconSize: 48,
                                  ),
                                  Tooltip(
                                    message: 'Forward 10 seconds',
                                    waitDuration: const Duration(
                                      milliseconds: 400,
                                    ),
                                    child: IconButton(
                                      icon: const Icon(Icons.forward_10),
                                      onPressed: canForward
                                          ? () => _seekRelative(skipInterval)
                                          : null,
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.skip_next),
                                    onPressed: () => _skip(1),
                                  ),
                                ],
                              );
                            },
                          );
                        },
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('Speed:'),
                      const SizedBox(width: 8),
                      DropdownButton<double>(
                        value: _speed,
                        items: [0.5, 1.0, 1.25, 1.5, 2.0]
                            .map(
                              (s) => DropdownMenuItem(
                                value: s,
                                child: Text('${s}x'),
                              ),
                            )
                            .toList(),
                        onChanged: (v) => v != null ? _setSpeed(v) : null,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
