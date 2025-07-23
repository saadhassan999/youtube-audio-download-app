import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import '../models/audio_file.dart';
import '../services/database_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/download_service.dart';

class AudioPlayerScreen extends StatefulWidget {
  @override
  _AudioPlayerScreenState createState() => _AudioPlayerScreenState();
}

class _AudioPlayerScreenState extends State<AudioPlayerScreen> with WidgetsBindingObserver {
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
        lastAudio = _playlist.firstWhere((a) => a.id == lastId, orElse: () => _playlist[0]);
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
      await prefs.setInt(_lastAudioPositionKey, _player.position.inMilliseconds);
      await prefs.setString(_lastAudioStateKey, _isPlaying ? 'playing' : 'paused');
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
    if (_audioFile == null) return Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(title: Text(_audioFile!.title)),
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(_audioFile!.channelName, style: TextStyle(fontSize: 16)),
          StreamBuilder<Duration?> (
            stream: _player.durationStream,
            builder: (context, snapshot) {
              final duration = snapshot.data ?? Duration.zero;
              return StreamBuilder<Duration>(
                stream: _player.positionStream,
                builder: (context, posSnap) {
                  final pos = posSnap.data ?? Duration.zero;
                  return Column(
                    children: [
                      Slider(
                        value: pos.inSeconds.toDouble(),
                        min: 0,
                        max: duration.inSeconds.toDouble(),
                        onChanged: (v) => _seek(Duration(seconds: v.toInt())),
                      ),
                      Text('${pos.toString().split(".")[0]} / ${duration.toString().split(".")[0]}'),
                    ],
                  );
                },
              );
            },
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(icon: Icon(Icons.skip_previous), onPressed: () => _skip(-1)),
              IconButton(
                icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                onPressed: _isPlaying ? _pause : _play,
                iconSize: 48,
              ),
              IconButton(icon: Icon(Icons.skip_next), onPressed: () => _skip(1)),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('Speed:'),
              DropdownButton<double>(
                value: _speed,
                items: [0.5, 1.0, 1.25, 1.5, 2.0].map((s) => DropdownMenuItem(value: s, child: Text('${s}x'))).toList(),
                onChanged: (v) => v != null ? _setSpeed(v) : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
} 