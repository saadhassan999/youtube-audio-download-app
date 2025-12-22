import 'package:flutter/material.dart';

import '../models/channel.dart';
import '../models/video.dart';
import '../repositories/video_repository.dart';
import '../services/database_service.dart';
import '../services/youtube_service.dart';
import '../utils/youtube_utils.dart';
import '../core/snackbar_bus.dart';

class AddItemScreen extends StatefulWidget {
  const AddItemScreen({super.key});

  @override
  State<AddItemScreen> createState() => _AddItemScreenState();
}

class _AddItemScreenState extends State<AddItemScreen> {
  final TextEditingController _controller = TextEditingController();
  bool _isSubmitting = false;
  String? _status;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _handleSubmit() async {
    final input = _controller.text.trim();
    if (input.isEmpty) {
      _setStatus('Please paste a channel handle or video link.');
      return;
    }

    setState(() {
      _isSubmitting = true;
      _status = null;
    });

    try {
      final videoId = tryParseVideoId(input);
      if (videoId != null) {
        await _saveVideo(videoId);
        if (!mounted) return;
        Navigator.pop(context, true);
        return;
      }

      final resolved = await resolveChannelFromInput(input);
      final existing =
          await DatabaseService.instance.getChannelById(resolved.id);
      if (existing != null) {
        // Optionally refresh metadata if it was missing before.
        if ((existing.thumbnailUrl.isEmpty && resolved.thumbnailUrl != null) ||
            (existing.name.isEmpty && resolved.name.isNotEmpty)) {
          await DatabaseService.instance.updateChannel(
            Channel(
              id: existing.id,
              name: resolved.name.isNotEmpty ? resolved.name : existing.name,
              description: existing.description,
              thumbnailUrl:
                  resolved.thumbnailUrl ?? existing.thumbnailUrl,
              lastVideoId: existing.lastVideoId,
              handle: existing.handle,
              subscriberCount: existing.subscriberCount,
              hiddenSubscriberCount: existing.hiddenSubscriberCount,
            ),
          );
        }
        _setStatus('Channel already added: ${existing.name}');
        setState(() => _isSubmitting = false);
        return;
      }

      await DatabaseService.instance.addChannel(
        Channel(
          id: resolved.id,
          name: resolved.name,
          thumbnailUrl: resolved.thumbnailUrl ?? '',
          lastVideoId: '',
          handle: resolved.handle,
        ),
      );
      if (!mounted) return;
      Navigator.pop(context, true);
      showGlobalSnackBarMessage('Channel added: ${resolved.name}');
    } catch (e) {
      _setStatus('Failed to add: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  Future<void> _saveVideo(String videoId) async {
    Video? video = await YouTubeService.getVideoById(videoId);
    video ??= Video(
      id: videoId,
      title: 'YouTube Audio',
      published: DateTime.now().toUtc(),
      thumbnailUrl: 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
      channelName: 'Unknown channel',
      channelId: '',
    );
    await VideoRepository.instance.upsertSavedVideo(video);
    if (!mounted) return;
    showGlobalSnackBarMessage('Saved to Saved Audios: ${video.title}');
  }

  void _setStatus(String message) {
    if (!mounted) return;
    setState(() {
      _status = message;
    });
    showGlobalSnackBarMessage(message);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Add channel or video')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _controller,
              decoration: const InputDecoration(
                labelText: 'Channel handle or video URL',
                hintText: '@handle, channel URL, or watch?v=...',
                border: OutlineInputBorder(),
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _handleSubmit(),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _isSubmitting ? null : _handleSubmit,
              icon: _isSubmitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add),
              label: const Text('Add'),
            ),
            if (_status != null) ...[
              const SizedBox(height: 12),
              Text(
                _status!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withOpacity(0.7),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
