import 'package:flutter/material.dart';
import '../models/channel.dart';
import '../services/youtube_service.dart';
import '../services/database_service.dart';
import 'dart:async';

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
  
  // Add this state
  bool _canAdd = false;

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
    // Listen to text changes to update button state
    _controller.addListener(() {
      setState(() {
        _canAdd = _controller.text.trim().isNotEmpty;
      });
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  void _onTextChanged(String query) {
    _currentQuery = query;
    
    // Cancel previous timer
    _debounceTimer?.cancel();
    
    if (query.trim().isEmpty) {
      setState(() {
        _suggestions = [];
        _showSuggestions = false;
        _isLoading = false;
      });
      return;
    }

    // Debounce the search to avoid too many API calls
    _debounceTimer = Timer(const Duration(milliseconds: 500), () async {
      if (_currentQuery == query) { // Only search if query hasn't changed
        await _searchChannels(query);
      }
    });
  }

  Future<void> _searchChannels(String query) async {
    if (query.trim().isEmpty) return;

    setState(() {
      _isLoading = true;
      _showSuggestions = true;
    });

    try {
      final suggestions = await YouTubeService.getChannelSuggestions(query);
      setState(() {
        _suggestions = suggestions;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _suggestions = [];
        _isLoading = false;
      });
      print('Error searching channels: $e');
    }
  }

  void _onSuggestionSelected(Channel channel) async {
    // Check if channel is already added
    final existingChannels = await DatabaseService.instance.getChannels();
    final isAlreadyAdded = existingChannels.any((c) => c.id == channel.id);
    
    if (isAlreadyAdded) {
      ScaffoldMessenger.of(context).showSnackBar(
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
    });
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Added channel: ${channel.name}')),
    );
  }

  void _onManualAdd() {
    final query = _controller.text.trim();
    if (query.isNotEmpty) {
      widget.onManualAdd(query);
      _controller.clear();
      setState(() {
        _suggestions = [];
        _showSuggestions = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Search input field
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            children: [
              Expanded(
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
              SizedBox(width: 8),
              IconButton(
                icon: Icon(Icons.add),
                onPressed: _canAdd ? _onManualAdd : null,
                tooltip: 'Add manually (URL/ID)',
              ),
            ],
          ),
        ),
        
        // Suggestions list
        if (_showSuggestions && (_suggestions.isNotEmpty || _isLoading))
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
            child: _isLoading
              ? Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: CircularProgressIndicator(),
                  ),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: _suggestions.length,
                  itemBuilder: (context, index) {
                    final channel = _suggestions[index];
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
                            color: Colors.grey[300],
                            child: Icon(Icons.person, color: Colors.grey[600]),
                          ),
                      title: Text(
                        channel.name,
                        style: TextStyle(fontWeight: FontWeight.w500),
                      ),
                      subtitle: channel.description.isNotEmpty
                        ? Text(
                            channel.description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12),
                          )
                        : null,
                      onTap: () => _onSuggestionSelected(channel),
                      trailing: Icon(Icons.add_circle_outline, color: Colors.blue),
                    );
                  },
                ),
          ),
      ],
    );
  }
} 