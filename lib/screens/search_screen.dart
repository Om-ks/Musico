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

class SearchScreen extends StatefulWidget {
  final VoidCallback? onOpenMenu;

  const SearchScreen({super.key, this.onOpenMenu});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  final _storage = StorageService();

  Timer? _debounce;
  List<Song> _results = [];
  List<MusicPlaylist> _playlists = [];
  List<String> _liveSuggestions = [];
  List<String> _recentSearches = [];
  bool _loading = false;
  bool _suggestionsLoading = false;
  bool _searched = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
    unawaited(_loadRecentSearches());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    final cleanQuery = query.trim();
    if (cleanQuery.isEmpty) return;

    _focus.unfocus();
    _debounce?.cancel();
    await _storage.addRecentSearch(cleanQuery);
    unawaited(_loadRecentSearches());
    setState(() {
      _loading = true;
      _searched = true;
      _liveSuggestions = [];
    });

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

  void _onQueryChanged(String value) {
    setState(() {});

    _debounce?.cancel();
    final cleanQuery = value.trim();
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

    _debounce = Timer(const Duration(milliseconds: 350), () {
      _loadSuggestions(cleanQuery);
    });
  }

  Future<void> _loadSuggestions(String query) async {
    setState(() => _suggestionsLoading = true);
    final suggestions = await ApiService.getSearchSuggestions(query);
    if (!mounted || _ctrl.text.trim() != query) return;

    setState(() {
      _liveSuggestions = suggestions;
      _suggestionsLoading = false;
    });
  }

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

  Future<void> _loadRecentSearches() async {
    final recent = await _storage.getRecentSearches();
    if (!mounted) return;
    setState(() => _recentSearches = recent);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            _searchBar(),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.menu_rounded, color: Colors.white70),
            onPressed: widget.onOpenMenu,
          ),
          const SizedBox(width: 8),
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

  Widget _body() {
    final query = _ctrl.text.trim();

    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFFB06EF3)),
      );
    }

    if (query.isEmpty && _recentSearches.isNotEmpty) {
      return _recentSearchesView();
    }

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

    if (!_searched) return _emptyPrompt();

    final showPlaylists =
        _playlists.isNotEmpty && (_results.isEmpty || _shouldShowPlaylists(query));

    if (_results.isEmpty && !showPlaylists) {
      return _centerMessage(
        icon: Icons.search_off_rounded,
        title: 'No results for "$query"',
        subtitle: 'Try a different song or artist name.',
      );
    }

    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 160),
      children: [
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
        ..._results.asMap().entries.map((entry) {
          final song = entry.value;
          return SongTile(
            song: song,
            index: entry.key + 1,
            onTap: () =>
                context.read<PlayerProvider>().playSong(song, playlist: _results),
          );
        }),
        if (showPlaylists) _playlistResults(),
      ],
    );
  }

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

  Widget _playlistArt() {
    return Container(
      width: 120,
      height: 120,
      color: const Color(0xFF1A1A2E),
      child: const Icon(Icons.queue_music, color: Color(0xFFB06EF3), size: 32),
    );
  }

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

  Widget _recentSearchesView() {
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 160),
      itemCount: _recentSearches.length + 1,
      itemBuilder: (context, index) {
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
          trailing: IconButton(
            icon: const Icon(Icons.close, color: Colors.white38, size: 20),
            onPressed: () async {
              await _storage.removeRecentSearch(query);
              await _loadRecentSearches();
            },
          ),
          onTap: () {
            _ctrl.text = query;
            _search(query);
          },
        );
      },
    );
  }

  Widget _emptyPrompt() {
    return _centerMessage(
      icon: Icons.search,
      title: 'Search Musico',
      subtitle: 'Type a song or artist name to load playable results.',
    );
  }

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
              style: const TextStyle(color: Colors.white30, fontSize: 13)),
        ],
      ),
    );
  }
}
