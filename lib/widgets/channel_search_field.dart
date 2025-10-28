import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/snackbar_bus.dart';
import '../models/channel.dart';
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

class _ChannelSearchFieldState extends State<ChannelSearchField>
    with WidgetsBindingObserver {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final LayerLink _layerLink = LayerLink();
  final GlobalKey _targetKey = GlobalKey();

  List<Channel> _suggestions = [];
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
        await _searchChannels(trimmed);
      }
    });
  }

  Future<void> _searchChannels(String query) async {
    if (query.isEmpty) return;

    final requestId = ++_searchRequestId;

    setState(() {
      _isLoading = true;
      _statusMessage = null;
      _statusIsError = false;
    });
    _updateOverlay();

    try {
      final suggestions = await YouTubeService.getChannelSuggestions(query);
      if (requestId != _searchRequestId) return;

      setState(() {
        _suggestions = suggestions;
        _isLoading = false;
        if (suggestions.isEmpty) {
          _statusMessage =
              'No channels found for "$query". Try a different name or paste the channel URL.';
          _statusIsError = false;
        }
      });
      _updateOverlay();
    } on RateLimitException catch (e) {
      if (requestId != _searchRequestId) return;
      final retryHint = e.retryAfter == null
          ? 'Please try again soon.'
          : 'Please try again in ${_formatRetryAfter(e.retryAfter!)}.';
      setState(() {
        _suggestions = [];
        _isLoading = false;
        _statusMessage = 'We’re hitting YouTube limits right now. $retryHint';
        _statusIsError = true;
      });
      _showSnackBar('YouTube rate limit reached. $retryHint');
      _updateOverlay();
    } on ChannelSearchException catch (e) {
      if (e.isCancellation || requestId != _searchRequestId) return;
      setState(() {
        _suggestions = [];
        _isLoading = false;
        _statusMessage = e.message;
        _statusIsError = true;
      });
      _showSnackBar(e.message);
      _updateOverlay();
    } catch (e) {
      if (requestId != _searchRequestId) return;
      setState(() {
        _suggestions = [];
        _isLoading = false;
        _statusMessage =
            'Something went wrong while searching. Please check your connection and try again.';
        _statusIsError = true;
      });
      _showSnackBar('Channel search failed. Please try again.');
      _updateOverlay();
    }
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
                color: Colors.grey.shade300,
                shape: BoxShape.circle,
              ),
            ),
            title: Container(
              height: 14,
              margin: EdgeInsets.only(bottom: 6),
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            subtitle: Container(
              height: 12,
              decoration: BoxDecoration(
                color: Colors.grey.shade200,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          );
        },
      );
    }

    if (_suggestions.isEmpty) {
      return Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          _statusMessage ?? 'No channels to display.',
          style: TextStyle(
            fontSize: 14,
            color: _statusIsError
                ? Theme.of(context).colorScheme.error
                : Theme.of(context).hintColor,
          ),
          textAlign: TextAlign.center,
        ),
      );
    }

    return ListView.builder(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      itemCount: _suggestions.length,
      itemBuilder: (context, index) {
        final channel = _suggestions[index];
        final handleText =
            channel.handle?.isNotEmpty == true ? channel.handle : null;
        final hasSubscriberCount =
            !channel.hiddenSubscriberCount && channel.subscriberCount != null;
        final subscriberText = hasSubscriberCount
            ? '${formatSubscriberCount(channel.subscriberCount)} subscribers'
            : 'Subscribers hidden';

        return ListTile(
          leading: channel.thumbnailUrl.isNotEmpty
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Image.network(
                    channel.thumbnailUrl,
                    width: 40,
                    height: 40,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) {
                      return Container(
                        width: 40,
                        height: 40,
                        color: Colors.grey[300],
                        child: Icon(Icons.person, color: Colors.grey[600]),
                      );
                    },
                  ),
                )
              : Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Icon(Icons.person, color: Colors.grey[600]),
                ),
          title: Text(
            channel.name,
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (handleText != null)
                Text(
                  handleText,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).textTheme.bodySmall?.color ??
                        Colors.grey[600],
                  ),
                ),
              Text(
                subscriberText,
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
            ],
          ),
          onTap: () => _onSuggestionSelected(channel),
          trailing: Icon(Icons.add_circle_outline, color: Colors.blue),
        );
      },
    );
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
    final fieldHeight =
        fieldSize.height > 0 ? fieldSize.height : kMinInteractiveDimension;
    final fieldWidth =
        fieldSize.width > 0 ? fieldSize.width : mediaQuery.size.width;

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
    final maxTop = math.max(
      0.0,
      screenHeight - bottomInset - 200.0,
    );
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
    dropdownMaxHeight =
        dropdownMaxHeight.clamp(0.0, screenHeight).toDouble();

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
            borderRadius: BorderRadius.circular(12),
            color: theme.cardColor,
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: dropdownMaxHeight,
              ),
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
          child: TextField(
            controller: _controller,
            focusNode: _focusNode,
            style: const TextStyle(color: Colors.black87),
            decoration: InputDecoration(
              labelText: 'Search for YouTube channels...',
              hintText: 'Type channel name (e.g., "PewDiePie", "MrBeast")',
              prefixIcon: Icon(Icons.search),
              suffixIcon: _isLoading
                  ? Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Colors.black26),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Colors.black12),
              ),
              filled: true,
              fillColor: Colors.white,
            ),
            onChanged: _onTextChanged,
            onSubmitted: (_) => _onManualAdd(),
          ),
        ),
      ),
    );
  }
}
