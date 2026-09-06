import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../models/music_playlist.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';
import '../widgets/song_tile.dart';
import 'playlist_detail_screen.dart';

// SearchScreen allows users to search online for songs, artists, and playlists.
// It features debounced auto-complete suggestions, saved recent search history,
// and dual-result display (songs list + horizontal playlist cards).
class SearchScreen extends StatefulWidget {
  // Callback invoked when tapping the top-left menu icon to open the drawer.
  final VoidCallback? onOpenMenu;

  // Constructor allowing an optional onOpenMenu callback.
  const SearchScreen({super.key, this.onOpenMenu});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

// State class managing search text input, debounce timers, autocomplete suggestions,
// recent search history, and search result lists.
class _SearchScreenState extends State<SearchScreen> {
  // Controller managing the search input text field.
  final _ctrl = TextEditingController();

  // Focus node to monitor whether the search input currently has keyboard focus.
  final _focus = FocusNode();

  // Storage service to persist and retrieve the user's recent search queries.
  final _storage = StorageService();

  // Debounce timer to delay autocomplete suggestion requests while the user is still typing.
  Timer? _debounce;

  // List of songs returned from the search query.
  List<Song> _results = [];

  // List of playlists returned from the search query.
  List<MusicPlaylist> _playlists = [];

  // Live autocomplete keyword suggestions returned from the API as the user types.
  List<String> _liveSuggestions = [];

  // List of previously searched queries saved on the device.
  List<String> _recentSearches = [];

  // Indicates whether a full search request is actively loading.
  bool _loading = false;

  // Indicates whether autocomplete suggestions are actively loading.
  bool _suggestionsLoading = false;

  // Set to true after a search query has been submitted.
  bool _searched = false;

  // Sets up focus listeners and loads saved recent search terms on screen startup.
  @override
  void initState() {
    super.initState();
    // Re-render UI when input gains or loses focus (e.g. to show suggestions vs results)
    _focus.addListener(() => setState(() {}));
    unawaited(_loadRecentSearches());
  }

  // Cancels any running timers and disposes text and focus controllers.
  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  // Executes a full search for both songs and playlists matching the query.
  // Saves the query to recent searches, hides the keyboard, and fetches results in parallel.
  Future<void> _search(String query) async {
    final cleanQuery = query.trim();
    if (cleanQuery.isEmpty) return;

    // Unfocus to dismiss the on-screen keyboard
    _focus.unfocus();
    _debounce?.cancel();
    // Save to local device history
    await _storage.addRecentSearch(cleanQuery);
    unawaited(_loadRecentSearches());

    setState(() {
      _loading = true;
      _searched = true;
      _liveSuggestions = [];
    });

    // Concurrently fetch songs (up to 50) and playlists (up to 10)
    final results = await Future.wait<dynamic>([
      ApiService.search(cleanQuery, limit: 50),
      ApiService.searchPlaylists(cleanQuery, limit: 10),
    ]);
    if (!mounted) return;

    setState(() {
      _results = results[0] as List<Song>;
      _playlists = results[1] as List<MusicPlaylist>;
      _loading = false;
    });
  }

  // Called every time the user types or deletes a character in the search input field.
  // Employs a 350ms debounce timer so we only query suggestions once the user pauses typing.
  void _onQueryChanged(String value) {
    setState(() {});

    _debounce?.cancel();
    final cleanQuery = value.trim();
    // If input is less than 2 characters, clear suggestions
    if (cleanQuery.length < 2) {
      setState(() {
        _liveSuggestions = [];
        _suggestionsLoading = false;
        if (cleanQuery.isEmpty) {
          _results = [];
          _playlists = [];
          _searched = false;
        }
      });
      return;
    }

    // Wait 350ms after the last keystroke before querying autocomplete suggestions
    _debounce = Timer(const Duration(milliseconds: 350), () {
      _loadSuggestions(cleanQuery);
    });
  }

  // Fetches live autocomplete suggestions from the API for the given query.
  Future<void> _loadSuggestions(String query) async {
    setState(() => _suggestionsLoading = true);
    final suggestions = await ApiService.getSearchSuggestions(query);
    // Discard result if user navigated away or changed the input text in the meantime
    if (!mounted || _ctrl.text.trim() != query) return;

    setState(() {
      _liveSuggestions = suggestions;
      _suggestionsLoading = false;
    });
  }

  // Clears the search text and resets all result and suggestion lists.
  void _clearSearch() {
    _debounce?.cancel();
    _ctrl.clear();
    setState(() {
      _results = [];
      _playlists = [];
      _liveSuggestions = [];
      _loading = false;
      _suggestionsLoading = false;
      _searched = false;
    });
  }

  // Loads recent search queries from local storage to display when search box is empty.
  Future<void> _loadRecentSearches() async {
    final recent = await _storage.getRecentSearches();
    if (!mounted) return;
    setState(() => _recentSearches = recent);
  }

  // Builds the search screen layout containing the search bar at the top and the dynamic content body below.
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true, // Automatically adjusts when the on-screen keyboard appears
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            // Top search bar input with menu icon and search button
            _searchBar(),
            // Dynamic content: recent searches, live suggestions, or search results
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  // Builds the top input bar with text field, clear button, and search action icon.
  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Row(
        children: [
          // Drawer menu toggle button
          IconButton(
            icon: const Icon(Icons.menu_rounded, color: Colors.white70),
            onPressed: widget.onOpenMenu,
          ),
          const SizedBox(width: 8),
          // Search text input box
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(12),
              ),
              child: TextField(
                controller: _ctrl,
                focusNode: _focus,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Search songs or artists...',
                  hintStyle: const TextStyle(color: Colors.white38),
                  prefixIcon: const Icon(Icons.search, color: Colors.white54),
                  border: InputBorder.none,
                  contentPadding:
                      const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
                  // Show clear 'X' button only when there is typed text
                  suffixIcon: _ctrl.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.close, color: Colors.white54),
                          onPressed: _clearSearch,
                        )
                      : null,
                ),
                onChanged: _onQueryChanged,
                onSubmitted: _search,
                textInputAction: TextInputAction.search,
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Purple square button to trigger search on tap
          GestureDetector(
            onTap: () => _search(_ctrl.text),
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: const Color(0xFFB06EF3),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.search, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  // Returns the appropriate widget based on current search and focus states:
  // 1. Loading spinner
  // 2. Recent searches history (when query is empty)
  // 3. Live autocomplete suggestions (while user is actively typing)
  // 4. Initial prompt (before searching)
  // 5. "No results" message
  // 6. Search results list (songs and playlists)
  Widget _body() {
    final query = _ctrl.text.trim();

    // 1. Show loading indicator while querying search APIs
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFFB06EF3)),
      );
    }

    // 2. Show recent search history if input is empty
    if (query.isEmpty && _recentSearches.isNotEmpty) {
      return _recentSearchesView();
    }

    // 3. Show live autocomplete suggestions while user is focused and typing
    if (_focus.hasFocus && query.length >= 2) {
      if (_suggestionsLoading && _liveSuggestions.isEmpty) {
        return Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              color: const Color(0xFFBB77FF).withValues(alpha: 0.6),
              strokeWidth: 2,
            ),
          ),
        );
      }
      if (_liveSuggestions.isNotEmpty) return _suggestionsView();
    }

    // 4. Show initial helpful prompt if user hasn't submitted a search yet
    if (!_searched) return _emptyPrompt();

    // Check whether playlists should be included in the results view
    final showPlaylists =
        _playlists.isNotEmpty && (_results.isEmpty || _shouldShowPlaylists(query));

    // 5. If no songs and no playlists match the query, display "No results"
    if (_results.isEmpty && !showPlaylists) {
      return _centerMessage(
        icon: Icons.search_off_rounded,
        title: 'No results for "$query"',
        subtitle: 'Try a different song or artist name.',
      );
    }

    // 6. Display search results (Song list followed by Playlist cards)
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 160),
      children: [
        // "Songs" section header with accent gradient pill
        if (_results.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
            child: Row(
              children: [
                Container(
                  width: 4,
                  height: 20,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFFBB77FF), Color(0xFF7BA7FF)],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  'Songs',
                  style: GoogleFonts.spaceGrotesk(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        // Song tiles list
        ..._results.asMap().entries.map((entry) {
          final song = entry.value;
          return SongTile(
            song: song,
            index: entry.key + 1,
            onTap: () =>
                context.read<PlayerProvider>().playSong(song, playlist: _results),
          );
        }),
        // Playlists horizontal carousel (if relevant)
        if (showPlaylists) _playlistResults(),
      ],
    );
  }

  // Determines whether the query suggests the user is looking for a playlist or soundtrack
  // (e.g., contains keywords like 'ost', 'soundtrack', 'playlist', 'album').
  bool _shouldShowPlaylists(String query) {
    final q = query.toLowerCase();
    return q.contains('playlist') ||
        q.contains('ost') ||
        q.contains('soundtrack') ||
        q.contains('score') ||
        q.contains('game') ||
        q.contains('level') ||
        q.contains('mix') ||
        q.contains('album');
  }

  // Builds the horizontal playlist results carousel shown beneath song search results.
  Widget _playlistResults() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text(
            'Playlists',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        SizedBox(
          height: 160,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: _playlists.length,
            itemBuilder: (context, index) {
              final playlist = _playlists[index];
              return GestureDetector(
                // Navigate to playlist detail screen on tap
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => RemotePlaylistScreen(playlist: playlist),
                  ),
                ),
                child: Container(
                  width: 120,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Square playlist artwork thumbnail
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: playlist.thumbnailUrl.isNotEmpty
                            ? CachedNetworkImage(
                                imageUrl: playlist.thumbnailUrl,
                                width: 120,
                                height: 120,
                                fit: BoxFit.cover,
                                placeholder: (_, __) => _playlistArt(),
                                errorWidget: (_, __, ___) => _playlistArt(),
                              )
                            : _playlistArt(),
                      ),
                      const SizedBox(height: 8),
                      // Playlist title text
                      Text(
                        playlist.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // Fallback placeholder container for playlists with missing or loading artwork.
  Widget _playlistArt() {
    return Container(
      width: 120,
      height: 120,
      color: const Color(0xFF1A1A2E),
      child: const Icon(Icons.queue_music, color: Color(0xFFB06EF3), size: 32),
    );
  }

  // Renders the list of live autocomplete keyword suggestions while the user types.
  // Tapping a suggestion fills the search field and runs the search immediately.
  Widget _suggestionsView() {
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 160),
      itemCount: _liveSuggestions.length,
      itemBuilder: (context, index) {
        final suggestion = _liveSuggestions[index];
        return ListTile(
          leading: const Icon(Icons.search, color: Colors.white38),
          title: Text(suggestion, style: const TextStyle(color: Colors.white)),
          onTap: () {
            _ctrl.text = suggestion;
            _search(suggestion);
          },
        );
      },
    );
  }

  // Renders the list of recent search queries saved locally on the user's device.
  // Users can tap a past search to run it again, delete individual queries, or clear all.
  Widget _recentSearchesView() {
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 160),
      itemCount: _recentSearches.length + 1,
      itemBuilder: (context, index) {
        // Top header row with "Recent Searches" label and "Clear" all button
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Recent Searches',
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold)),
                TextButton(
                  onPressed: () async {
                    await _storage.clearRecentSearches();
                    await _loadRecentSearches();
                  },
                  child: const Text('Clear',
                      style: TextStyle(color: Color(0xFFB06EF3))),
                ),
              ],
            ),
          );
        }

        final query = _recentSearches[index - 1];
        return ListTile(
          leading: const Icon(Icons.history, color: Colors.white38),
          title: Text(query, style: const TextStyle(color: Colors.white70)),
          // Delete single search history entry
          trailing: IconButton(
            icon: const Icon(Icons.close, color: Colors.white38, size: 20),
            onPressed: () async {
              await _storage.removeRecentSearch(query);
              await _loadRecentSearches();
            },
          ),
          // Tap to search this query again
          onTap: () {
            _ctrl.text = query;
            _search(query);
          },
        );
      },
    );
  }

  // Placeholder message shown when the user first opens the search screen.
  Widget _emptyPrompt() {
    return _centerMessage(
      icon: Icons.search,
      title: 'Search Musico',
      subtitle: 'Type a song or artist name to load playable results.',
    );
  }

  // Reusable helper widget to center a faded icon, bold title, and informative subtitle.
  Widget _centerMessage({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: Colors.white12, size: 64),
          const SizedBox(height: 16),
          Text(title,
              style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 16,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white30, fontSize: 13)),
        ],
      ),
    );
  }
}
