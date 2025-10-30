import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/snackbar_bus.dart';
import '../models/channel.dart';
import '../models/video.dart';
import '../repositories/video_repository.dart';
import '../services/database_service.dart';
import '../services/youtube_service.dart';
import '../utils/youtube_utils.dart';

class ChannelSearchField extends StatefulWidget {
  final Function(Channel) onChannelSelected;
  final Function(String) onManualAdd;

  const ChannelSearchField({
    Key? key,
    required this.onChannelSelected,
    required this.onManualAdd,
  }) : super(key: key);

  @override
  State<ChannelSearchField> createState() => _ChannelSearchFieldState();
}

enum _SuggestionType { channel, video }

class _SearchSuggestion {
  _SearchSuggestion.channel(this.channel)
    : video = null,
      type = _SuggestionType.channel;

  _SearchSuggestion.video(this.video)
    : channel = null,
      type = _SuggestionType.video;

  final _SuggestionType type;
  final Channel? channel;
  final Video? video;
}

class _ChannelSearchFieldState extends State<ChannelSearchField>
    with WidgetsBindingObserver {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final LayerLink _layerLink = LayerLink();
  final GlobalKey _targetKey = GlobalKey();

  List<_SearchSuggestion> _suggestions = [];
  bool _isLoading = false;
  Timer? _debounceTimer;
  String _currentQuery = '';
  String? _statusMessage;
  bool _statusIsError = false;
  int _searchRequestId = 0;

  OverlayEntry? _overlayEntry;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _focusNode.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    YouTubeService.cancelActiveSearch();
    _closeOverlay();
    _controller.dispose();
    _focusNode
      ..removeListener(_handleFocusChange)
      ..dispose();
    _debounceTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    // Rebuild overlay when keyboard or viewport metrics change.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _updateOverlay();
      }
    });
  }

  void _onTextChanged(String query) {
    _currentQuery = query;

    _debounceTimer?.cancel();
    YouTubeService.cancelActiveSearch();

    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _suggestions = [];
        _isLoading = false;
        _statusMessage = null;
        _statusIsError = false;
      });
      _updateOverlay();
      return;
    }

    _debounceTimer = Timer(const Duration(milliseconds: 350), () async {
      if (_currentQuery.trim() == trimmed) {
        await _searchSuggestions(trimmed);
      }
    });
  }

  Future<void> _searchSuggestions(String query) async {
    if (query.isEmpty) return;

    final requestId = ++_searchRequestId;

    setState(() {
      _isLoading = true;
      _statusMessage = null;
      _statusIsError = false;
    });
    _updateOverlay();

    List<Channel> channels = const [];
    List<Video> videos = const [];
    ChannelSearchException? channelError;
    ChannelSearchException? videoError;
    RateLimitException? rateLimit;

    try {
      channels = await YouTubeService.getChannelSuggestions(query);
    } on RateLimitException catch (e) {
      rateLimit = e;
    } on ChannelSearchException catch (e) {
      if (!e.isCancellation) {
        channelError = e;
      }
    } catch (e) {
      channelError = ChannelSearchException(e.toString(), cause: e);
    }

    try {
      videos = await YouTubeService.getVideoSuggestions(query);
    } on RateLimitException catch (e) {
      rateLimit = e;
    } on ChannelSearchException catch (e) {
      if (!e.isCancellation) {
        videoError = e;
      }
    } catch (e) {
      videoError = ChannelSearchException(e.toString(), cause: e);
    }

    if (requestId != _searchRequestId) {
      return;
    }

    final merged = <_SearchSuggestion>[
      ...channels.map(_SearchSuggestion.channel),
      ...videos.map(_SearchSuggestion.video),
    ];

    String? statusMessage;
    bool statusIsError = false;

    if (rateLimit != null && merged.isEmpty) {
      final retryHint = rateLimit.retryAfter == null
          ? 'Please try again soon.'
          : 'Please try again in ${_formatRetryAfter(rateLimit.retryAfter!)}.';
      statusMessage = 'We’re hitting YouTube limits right now. $retryHint';
      statusIsError = true;
      _showSnackBar('YouTube rate limit reached. $retryHint');
    } else {
      if (channelError != null && channels.isEmpty) {
        statusMessage = channelError.message;
        statusIsError = true;
      } else if (videoError != null && videos.isEmpty) {
        statusMessage = videoError.message;
        statusIsError = true;
      } else if (merged.isEmpty) {
        statusMessage =
            'No channels or videos found for "$query". Try a different name or paste a link.';
      }

      if (channelError != null && channels.isNotEmpty) {
        _showSnackBar(channelError.message);
      }
      if (videoError != null && videos.isNotEmpty) {
        _showSnackBar(videoError.message);
      }
    }

    setState(() {
      _suggestions = merged;
      _isLoading = false;
      _statusMessage = statusMessage;
      _statusIsError = statusIsError;
    });
    _updateOverlay();
  }

  void _onSuggestionSelected(Channel channel) async {
    YouTubeService.cancelActiveSearch();
    final existingChannels = await DatabaseService.instance.getChannels();
    final isAlreadyAdded = existingChannels.any((c) => c.id == channel.id);

    if (isAlreadyAdded) {
      showGlobalSnackBar(
        SnackBar(content: Text('Channel "${channel.name}" is already added')),
      );
      return;
    }

    await DatabaseService.instance.addChannel(channel);
    widget.onChannelSelected(channel);

    _controller.clear();
    setState(() {
      _suggestions = [];
      _statusMessage = null;
      _statusIsError = false;
    });
    _focusNode.unfocus();
    _updateOverlay();

    showGlobalSnackBarMessage('Added channel: ${channel.name}');
  }

  Future<void> _onVideoSelected(Video video) async {
    YouTubeService.cancelActiveSearch();
    try {
      await VideoRepository.instance.upsertSavedVideo(video);
      _controller.clear();
      setState(() {
        _suggestions = [];
        _statusMessage = null;
        _statusIsError = false;
      });
      _focusNode.unfocus();
      _updateOverlay();
      showGlobalSnackBarMessage('Saved to Saved Videos: ${video.title}');
    } catch (e) {
      _showSnackBar('Failed to save video: $e');
    }
  }

  void _onManualAdd() {
    final query = _controller.text.trim();
    if (query.isNotEmpty) {
      YouTubeService.cancelActiveSearch();
      widget.onManualAdd(query);
      _controller.clear();
      setState(() {
        _suggestions = [];
        _statusMessage = null;
        _statusIsError = false;
      });
      _focusNode.unfocus();
      _updateOverlay();
    }
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    showGlobalSnackBarMessage(message);
  }

  String _formatRetryAfter(Duration duration) {
    if (duration.inHours >= 1) {
      final hours = duration.inHours;
      final minutes = duration.inMinutes % 60;
      return minutes > 0 ? '${hours}h ${minutes}m' : '${hours}h';
    }
    if (duration.inMinutes >= 1) {
      final minutes = duration.inMinutes;
      final seconds = duration.inSeconds % 60;
      return seconds > 0 ? '${minutes}m ${seconds}s' : '${minutes}m';
    }
    final seconds = duration.inSeconds.clamp(1, 59);
    return '${seconds}s';
  }

  Widget _buildSuggestionsContent(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final textTheme = theme.textTheme;
    final skeletonColor = cs.surfaceVariant.withOpacity(0.6);

    if (_isLoading) {
      return ListView.builder(
        padding: EdgeInsets.zero,
        itemCount: 5,
        itemBuilder: (context, index) {
          return ListTile(
            leading: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: skeletonColor,
                shape: BoxShape.circle,
              ),
            ),
            title: Container(
              height: 14,
              margin: const EdgeInsets.only(bottom: 6),
              decoration: BoxDecoration(
                color: skeletonColor,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            subtitle: Container(
              height: 12,
              decoration: BoxDecoration(
                color: skeletonColor.withOpacity(0.8),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          );
        },
      );
    }

    if (_suggestions.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          _statusMessage ?? 'No results to display.',
          style: textTheme.bodyMedium?.copyWith(
                color: _statusIsError
                    ? cs.error
                    : cs.onSurface.withOpacity(0.75),
              ) ??
              TextStyle(
                color: _statusIsError
                    ? cs.error
                    : cs.onSurface.withOpacity(0.75),
              ),
          textAlign: TextAlign.center,
        ),
      );
    }

    return ListView.separated(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      separatorBuilder: (context, index) =>
          Divider(height: 1, color: cs.outlineVariant),
      itemCount: _suggestions.length,
      itemBuilder: (context, index) {
        final suggestion = _suggestions[index];
        if (suggestion.type == _SuggestionType.channel) {
          final channel = suggestion.channel;
          if (channel == null) {
            return const SizedBox.shrink();
          }
          return _buildChannelSuggestionTile(
            context,
            channel,
            isFirstChannel:
                index == 0 ||
                _suggestions[index - 1].type != _SuggestionType.channel,
          );
        }
        final video = suggestion.video;
        if (video == null) {
          return const SizedBox.shrink();
        }
        return _buildVideoSuggestionTile(
          context,
          video,
          isFirstVideo:
              index == 0 ||
              _suggestions[index - 1].type != _SuggestionType.video,
        );
      },
    );
  }

  Widget _buildChannelSuggestionTile(
    BuildContext context,
    Channel channel, {
    bool isFirstChannel = false,
  }) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final textTheme = theme.textTheme;
    final handleText = channel.handle?.isNotEmpty == true
        ? channel.handle
        : null;
    final hasSubscriberCount =
        !channel.hiddenSubscriberCount && channel.subscriberCount != null;
    final subscriberText = hasSubscriberCount
        ? '${formatSubscriberCount(channel.subscriberCount)} subscribers'
        : 'Subscribers hidden';

    final children = <Widget>[];
    if (isFirstChannel) {
      children.add(_buildSuggestionHeader(context, 'Channels'));
    }
    children.add(
      ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        leading: _buildChannelAvatar(channel.thumbnailUrl),
        title: Text(
          channel.name,
          style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ) ??
              TextStyle(
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (handleText != null)
              Text(
                handleText,
                style: textTheme.bodySmall?.copyWith(
                      color: cs.onSurface.withOpacity(0.7),
                    ) ??
                    TextStyle(
                      fontSize: 12,
                      color: cs.onSurface.withOpacity(0.7),
                    ),
              ),
            Text(
              subscriberText,
              style: textTheme.bodySmall?.copyWith(
                    color: cs.onSurface.withOpacity(0.7),
                  ) ??
                  TextStyle(
                    fontSize: 12,
                    color: cs.onSurface.withOpacity(0.7),
                  ),
            ),
          ],
        ),
        onTap: () => _onSuggestionSelected(channel),
        trailing: Icon(
          Icons.add_circle_outline,
          color: cs.primary,
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _buildVideoSuggestionTile(
    BuildContext context,
    Video video, {
    bool isFirstVideo = false,
  }) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final textTheme = theme.textTheme;
    final children = <Widget>[];
    if (isFirstVideo) {
      children.add(_buildSuggestionHeader(context, 'Videos'));
    }
    children.add(
      ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        leading: _buildVideoThumbnail(video.thumbnailUrl, video.duration),
        title: Text(
          video.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ) ??
              TextStyle(
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
        ),
        subtitle: Text(
          video.channelName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: textTheme.bodySmall?.copyWith(
                color: cs.onSurface.withOpacity(0.7),
              ) ??
              TextStyle(
                fontSize: 12,
                color: cs.onSurface.withOpacity(0.7),
              ),
        ),
        trailing: Icon(Icons.library_add, color: cs.primary),
        onTap: () => _onVideoSelected(video),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _buildSuggestionHeader(BuildContext context, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
            ) ??
            TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
            ),
      ),
    );
  }

  Widget _buildChannelAvatar(String thumbnailUrl) {
    final theme = this.context.mounted ? Theme.of(this.context) : null;
    final cs = theme?.colorScheme;
    final placeholderColor = cs?.surfaceVariant ?? Colors.grey.shade300;
    final iconColor = cs?.onSurfaceVariant ?? Colors.grey.shade600;
    if (thumbnailUrl.isEmpty) {
      return Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: placeholderColor,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Icon(Icons.person, color: iconColor),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Image.network(
        thumbnailUrl,
        width: 40,
        height: 40,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) {
          return Container(
            width: 40,
            height: 40,
            color: placeholderColor,
            child: Icon(Icons.person, color: iconColor),
          );
        },
      ),
    );
  }

  Widget _buildVideoThumbnail(String url, Duration? duration) {
    final theme = this.context.mounted ? Theme.of(this.context) : null;
    final cs = theme?.colorScheme;
    final placeholderColor = cs?.surfaceVariant ?? Colors.grey.shade300;
    final iconColor = cs?.onSurfaceVariant ?? Colors.grey.shade600;
    final overlayColor =
        cs?.scrim.withOpacity(0.7) ?? Colors.black.withOpacity(0.7);
    final overlayTextColor =
        cs?.onInverseSurface ?? Colors.white.withOpacity(0.94);
    final durationLabel = duration != null
        ? _formatVideoDuration(duration)
        : null;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 88,
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (url.isNotEmpty)
                Image.network(
                  url,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stack) => Container(
                    color: placeholderColor,
                    child: Icon(Icons.videocam, color: iconColor),
                  ),
                )
              else
                Container(
                  color: placeholderColor,
                  child: Icon(Icons.videocam, color: iconColor),
                ),
              if (durationLabel != null)
                Positioned(
                  right: 4,
                  bottom: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: overlayColor,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      durationLabel,
                      style: theme?.textTheme.labelSmall?.copyWith(
                            color: overlayTextColor,
                            fontWeight: FontWeight.w600,
                          ) ??
                          TextStyle(
                            color: overlayTextColor,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatVideoDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    final buffer = StringBuffer();
    if (hours > 0) {
      buffer.write(hours.toString());
      buffer.write(':');
      buffer.write(minutes.toString().padLeft(2, '0'));
    } else {
      buffer.write(minutes.toString());
    }
    buffer.write(':');
    buffer.write(seconds.toString().padLeft(2, '0'));
    return buffer.toString();
  }

  bool get _shouldShowOverlay {
    return _focusNode.hasFocus &&
        (_isLoading ||
            _suggestions.isNotEmpty ||
            (_statusMessage != null && _statusMessage!.isNotEmpty));
  }

  void _handleFocusChange() {
    if (_focusNode.hasFocus) {
      _updateOverlay();
    } else {
      _closeOverlay();
    }
  }

  void _updateOverlay() {
    if (!mounted) return;
    if (!_shouldShowOverlay) {
      _closeOverlay();
      return;
    }

    if (_overlayEntry == null) {
      final overlay = Overlay.of(context, rootOverlay: true);
      _overlayEntry = OverlayEntry(builder: _buildOverlay);
      overlay.insert(_overlayEntry!);
    } else {
      _overlayEntry!.markNeedsBuild();
    }
  }

  void _closeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  Widget _buildOverlay(BuildContext context) {
    final theme = Theme.of(this.context);
    final mediaQuery = MediaQuery.of(this.context);
    final ime = mediaQuery.viewInsets.bottom;
    final safe = mediaQuery.padding.bottom;
    final bottomInset = ime > 0 ? ime : safe;

    final renderBox =
        _targetKey.currentContext?.findRenderObject() as RenderBox?;
    final fieldSize = renderBox?.size ?? Size.zero;
    final fieldOrigin = renderBox?.localToGlobal(Offset.zero) ?? Offset.zero;
    final fieldHeight = fieldSize.height > 0
        ? fieldSize.height
        : kMinInteractiveDimension;
    final fieldWidth = fieldSize.width > 0
        ? fieldSize.width
        : mediaQuery.size.width;

    final screenWidth = mediaQuery.size.width;
    final screenHeight = mediaQuery.size.height;

    double dropdownWidth = fieldWidth;
    double left = fieldOrigin.dx;

    if (dropdownWidth <= 0) {
      const fallbackPadding = 16.0;
      dropdownWidth = screenWidth - (fallbackPadding * 2);
      left = fallbackPadding;
    }

    final desiredTop = fieldOrigin.dy + fieldHeight + 8.0;
    final maxTop = math.max(0.0, screenHeight - bottomInset - 200.0);
    final top = desiredTop.clamp(0.0, maxTop).toDouble();

    final availableSpace = (screenHeight - bottomInset) - top;
    double dropdownMaxHeight;
    if (availableSpace.isFinite && availableSpace > 0) {
      dropdownMaxHeight = math.min(availableSpace, screenHeight * 0.6);
      if (availableSpace >= 200.0) {
        dropdownMaxHeight = math.max(200.0, dropdownMaxHeight);
      }
    } else {
      dropdownMaxHeight = screenHeight * 0.6;
    }
    dropdownMaxHeight = dropdownMaxHeight.clamp(0.0, screenHeight).toDouble();

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () {
              _focusNode.unfocus();
              _closeOverlay();
            },
          ),
        ),
          Positioned(
            left: left,
            top: top,
            width: dropdownWidth,
            child: Material(
              elevation: 8,
              color: theme.colorScheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: dropdownMaxHeight),
                child: _buildSuggestionsContent(context),
              ),
            ),
          ),
        ],
      );
    }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: KeyedSubtree(
        key: _targetKey,
        child: SizedBox(
          width: double.infinity,
          child: Builder(
            builder: (context) {
              final theme = Theme.of(context);
              final cs = theme.colorScheme;
              return TextField(
                controller: _controller,
                focusNode: _focusNode,
                style: theme.textTheme.bodyLarge,
                decoration: InputDecoration(
                  labelText: 'Search channels or videos...',
                  hintText:
                      'Try a channel or video (e.g., "MrBeast", "lofi beats")',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _isLoading
                      ? Padding(
                          padding: const EdgeInsets.all(12),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation(cs.primary),
                            ),
                          ),
                        )
                      : null,
                ),
                onChanged: _onTextChanged,
                onSubmitted: (_) => _onManualAdd(),
              );
            },
          ),
        ),
      ),
    );
  }
}
