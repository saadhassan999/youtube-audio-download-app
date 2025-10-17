import 'package:flutter/material.dart';
import 'dart:async';

import '../models/channel.dart';
import '../services/database_service.dart';
import '../services/youtube_service.dart';
import '../utils/youtube_utils.dart';
import '../core/snackbar_bus.dart';

class ChannelSearchField extends StatefulWidget {
  final Function(Channel) onChannelSelected;
  final Function(String) onManualAdd;

  const ChannelSearchField({
    Key? key,
    required this.onChannelSelected,
    required this.onManualAdd,
  }) : super(key: key);

  @override
  _ChannelSearchFieldState createState() => _ChannelSearchFieldState();
}

class _ChannelSearchFieldState extends State<ChannelSearchField> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  List<Channel> _suggestions = [];
  bool _isLoading = false;
  bool _showSuggestions = false;
  Timer? _debounceTimer;
  String _currentQuery = '';
  String? _statusMessage;
  bool _statusIsError = false;
  int _searchRequestId = 0;

  // Add this state
  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus) {
        setState(() {
          _showSuggestions = false;
        });
      }
    });
  }

  @override
  void dispose() {
    YouTubeService.cancelActiveSearch();
    _controller.dispose();
    _focusNode.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  void _onTextChanged(String query) {
    _currentQuery = query;

    // Cancel previous timer
    _debounceTimer?.cancel();
    YouTubeService.cancelActiveSearch();

    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _suggestions = [];
        _showSuggestions = false;
        _isLoading = false;
        _statusMessage = null;
        _statusIsError = false;
      });
      return;
    }

    // Debounce the search to avoid too many API calls
    _debounceTimer = Timer(const Duration(milliseconds: 350), () async {
      if (_currentQuery.trim() == trimmed) {
        // Only search if query hasn't changed
        await _searchChannels(trimmed);
      }
    });
  }

  Future<void> _searchChannels(String query) async {
    if (query.isEmpty) return;

    final requestId = ++_searchRequestId;

    setState(() {
      _isLoading = true;
      _showSuggestions = true;
      _statusMessage = null;
      _statusIsError = false;
    });

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
    } on ChannelSearchException catch (e) {
      if (e.isCancellation || requestId != _searchRequestId) return;
      setState(() {
        _suggestions = [];
        _isLoading = false;
        _statusMessage = e.message;
        _statusIsError = true;
      });
      _showSnackBar(e.message);
    } catch (e) {
      if (requestId != _searchRequestId) return;
      setState(() {
        _suggestions = [];
        _isLoading = false;
        _statusMessage =
            'Something went wrong while searching. Please check your connection and try again.';
        _statusIsError = true;
      });
      print('Error searching channels: $e');
      _showSnackBar('Channel search failed. Please try again.');
    }
  }

  void _onSuggestionSelected(Channel channel) async {
    YouTubeService.cancelActiveSearch();
    // Check if channel is already added
    final existingChannels = await DatabaseService.instance.getChannels();
    final isAlreadyAdded = existingChannels.any((c) => c.id == channel.id);

    if (isAlreadyAdded) {
      showGlobalSnackBar(
        SnackBar(content: Text('Channel "${channel.name}" is already added')),
      );
      return;
    }

    // Add the channel
    await DatabaseService.instance.addChannel(channel);
    widget.onChannelSelected(channel);

    // Clear the search field
    _controller.clear();
    setState(() {
      _suggestions = [];
      _showSuggestions = false;
      _statusMessage = null;
      _statusIsError = false;
    });

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
        _showSuggestions = false;
        _statusMessage = null;
        _statusIsError = false;
      });
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
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: 5,
        padding: EdgeInsets.symmetric(vertical: 4),
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
              width: double.infinity,
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
      itemCount: _suggestions.length,
      itemBuilder: (context, index) {
        final channel = _suggestions[index];
        final handleText = channel.handle?.isNotEmpty == true
            ? channel.handle
            : null;
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
                    color:
                        Theme.of(context).textTheme.bodySmall?.color ??
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

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Search input field
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: TextField(
            controller: _controller,
            focusNode: _focusNode,
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
            ),
            onChanged: _onTextChanged,
            onSubmitted: (_) => _onManualAdd(),
          ),
        ),

        // Suggestions list
        if (_showSuggestions &&
            (_suggestions.isNotEmpty || _isLoading || _statusMessage != null))
          Container(
            constraints: BoxConstraints(maxHeight: 300),
            margin: EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black12,
                  blurRadius: 4,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: _buildSuggestionsContent(context),
          ),
      ],
    );
  }
}
