import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/music_playlist.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/account_provider.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';
import '../services/youtube_account_service.dart';
import '../widgets/mini_player.dart';
import '../widgets/song_tile.dart';
import '../widgets/add_to_playlist_sheet.dart';


// RemotePlaylistScreen displays the songs contained inside a remote playlist (such as YouTube Music).
// It fetches tracks from online APIs, supports song removal, and offers queue playback.
class RemotePlaylistScreen extends StatefulWidget {
  // The playlist metadata object containing id, title, owner, and artwork URL.
  final MusicPlaylist playlist;

  // Constructor requiring the playlist model.
  const RemotePlaylistScreen({
    super.key,
    required this.playlist,
  });

  @override
  State<RemotePlaylistScreen> createState() => _RemotePlaylistScreenState();
}

// PlaylistDetailScreen is a convenience subclass of RemotePlaylistScreen.
// It accepts flat parameters (playlistId, playlistTitle, etc.) and constructs the MusicPlaylist model.
class PlaylistDetailScreen extends RemotePlaylistScreen {
  PlaylistDetailScreen({
    super.key,
    required String playlistId,
    required String playlistTitle,
    required String playlistOwner,
    required String thumbnailUrl,
  }) : super(
          playlist: MusicPlaylist(
            id: playlistId,
            title: playlistTitle,
            owner: playlistOwner,
            thumbnailUrl: thumbnailUrl,
            itemCount: 0,
            source: 'youtube',
          ),
        );
}

// State class managing network fetching of playlist tracks, optimistic UI updates,
// and song removal for remote YouTube playlists.
class _RemotePlaylistScreenState extends State<RemotePlaylistScreen> {
  // In-memory list of songs belonging to this remote playlist.
  List<Song> _songs = [];

  // Indicates whether songs are actively being fetched from the internet.
  bool _loading = true;

  // Helper getter checking if this playlist represents YouTube's special "Liked Music" auto-playlist ('LM' or 'VLLM').
  bool get _isLikedPlaylist =>
      widget.playlist.id == 'LM' || widget.playlist.id == 'VLLM';

  // Triggers playlist song fetching when the screen is first opened.
  @override
  void initState() {
    super.initState();
    _load();
  }

  // Fetches songs from YouTube Music APIs with fallback to scraper if unauthorized.
  Future<void> _load() async {
    setState(() => _loading = true);
    final account = context.read<AccountProvider>();
    List<Song> songs = [];

    final headers = await account.getAuthHeaders() ?? <String, String>{};

    // Special case: YouTube "Liked Music" requires authenticated user cookies and pagination
    if (_isLikedPlaylist) {
      // Wait for cookie to be loaded from SharedPreferences before fetching
      await account.ready;
      // Re-get headers now that the cookie is guaranteed to be loaded
      final freshHeaders = await account.getAuthHeaders() ?? <String, String>{};
      // For Liked Music: fetch directly from YouTube with full pagination
      try {
        songs = await YoutubeAccountService().fetchPlaylistSongs(
          freshHeaders,
          'VLLM',
          album: 'Liked Music',
        );
        // Sync fetched songs into the app library (Library tab will reflect these)
        if (songs.isNotEmpty && account.youtubeAuthorized) {
          account.updateLikedSongsFromDirectFetch(songs);
        }
      } catch (e) {
        debugPrint('Liked songs direct fetch failed: $e');
      }
      // Fallback to library cache if fetch returned nothing
      if (songs.isEmpty) {
        songs = account.library.likedSongs;
      }
    } else {
      // General case: fetch regular YouTube playlist songs using user credentials if signed in
      try {
        songs = await YoutubeAccountService().fetchPlaylistSongs(
          headers,
          widget.playlist.id,
          album: widget.playlist.title,
        );
      } catch (e) {
        debugPrint('InnerTube playlist fetch failed: $e');
      }

      // Fallback to public Data API / Scraper if user is logged out or authenticated fetch failed
      if (songs.isEmpty) {
        try {
          songs = await ApiService.getPlaylistSongs(widget.playlist);
        } catch (e) {
          debugPrint('Public playlist fetch fallback failed: $e');
        }
      }
    }

    if (!mounted) return;
    setState(() {
      _songs = songs;
      _loading = false;
    });
  }

  // Optimistically removes a song from the displayed list, then notifies YouTube Music in the background.
  Future<void> _removeSong(Song song) async {
    // Immediate UI update so user doesn't experience lag
    setState(() {
      _songs.removeWhere((s) => s.id == song.id);
    });

    final account = context.read<AccountProvider>();
    // If logged in, call YouTube API to remove track from playlist on the server
    if (account.hasLiveSession && account.youtubeAuthorized) {
      final headers = await account.getAuthHeaders();
      if (headers != null) {
        final ok = await YoutubeAccountService().removeSongFromPlaylist(
          headers,
          widget.playlist.id,
          song.id,
          song.setVideoId,
        );
        if (ok) {
          // Trigger asynchronous refresh of library in background
          unawaited(account.refreshLibrary());
        }
      }
    }
  }

  // Displays a bottom sheet with action options for a long-pressed song
  void _showSongOptions(BuildContext context, Song song) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF111118),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              // Drag handle bar indicator at the top of the modal sheet
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              const SizedBox(height: 12),
              // Header showing thumbnail, song title, and artist name
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    // Album art thumbnail with rounded corners
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: song.thumbnailUrl.isNotEmpty
                          ? CachedNetworkImage(
                              imageUrl: song.thumbnailUrl,
                              width: 40,
                              height: 40,
                              fit: BoxFit.cover,
                              errorWidget: (_, __, ___) => const Icon(Icons.music_note, color: Color(0xFFB06EF3)),
                              placeholder: (_, __) => const Icon(Icons.music_note, color: Color(0xFFB06EF3)),
                            )
                          : const Icon(Icons.music_note, color: Color(0xFFB06EF3)),
                    ),
                    const SizedBox(width: 12),
                    // Song title and artist details
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            song.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            song.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(color: Colors.white12),
              // Option to remove the song from this remote playlist
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                title: const Text(
                  'Remove from this playlist',
                  style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w600),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _removeSong(song);
                },
              ),
              // Option to add this song to another local playlist
              ListTile(
                leading: const Icon(Icons.playlist_add_rounded, color: Colors.white),
                title: const Text(
                  'Add to other playlist',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                ),
                onTap: () {
                  Navigator.pop(context);
                  showAddToPlaylistSheet(context, song);
                },
              ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // Scaffold provides the visual structure: app bar, mini player, and scrollable track list
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      appBar: AppBar(
        title: Text(
          widget.playlist.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: 'Share Playlist',
            onPressed: () {
              final url = 'https://music.youtube.com/playlist?list=${widget.playlist.id}';
              Share.share('Check out this playlist: ${widget.playlist.title}\n$url');
            },
          ),
        ],
      ),
      // Persistent mini music player pinned at the bottom above safe area
      bottomNavigationBar: const SafeArea(child: MiniPlayer()),
      // Show loading spinner while fetching songs, otherwise show custom sliver scroll view
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFFB06EF3)),
            )
          : CustomScrollView(
              slivers: [
                // Top header banner with playlist cover art, title, and metadata
                SliverToBoxAdapter(child: _remoteHeader()),
                if (_songs.isEmpty)
                  // Empty state placeholder if no songs are found
                  const SliverFillRemaining(
                    child: _PlaylistEmptyMessage(
                      icon: Icons.queue_music_outlined,
                      title: 'No songs loaded',
                      subtitle: 'This playlist may be unavailable right now.',
                    ),
                  )
                else
                  // Scrollable sliver list of song tiles
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) => SongTile(
                        song: _songs[index],
                        index: index + 1,
                        // Tapping a song plays it and queues the rest of the playlist
                        onTap: () => context
                            .read<PlayerProvider>()
                            .playSong(_songs[index], playlist: _songs),
                        // Long pressing opens the action bottom sheet (remove, add to playlist)
                        onLongPress: () => _showSongOptions(context, _songs[index]),
                      ),
                      childCount: _songs.length,
                    ),
                  ),
                // Bottom spacing so the last song isn't obscured by the mini player
                const SliverToBoxAdapter(child: SizedBox(height: 130)),
              ],
            ),
    );
  }

  // Builds the top header widget displaying playlist cover art and information
  Widget _remoteHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
      child: Row(
        children: [
          // Playlist thumbnail image with rounded corners
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: widget.playlist.thumbnailUrl.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: widget.playlist.thumbnailUrl,
                    width: 92,
                    height: 92,
                    fit: BoxFit.cover,
                    placeholder: (_, __) => _defaultArt(),
                    errorWidget: (_, __, ___) => _defaultArt(),
                  )
                : _defaultArt(),
          ),
          const SizedBox(width: 16),
          // Title, creator/owner, and song count
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.playlist.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.spaceGrotesk(
                    color: Colors.white,
                    fontSize: 21,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${widget.playlist.owner} • ${_songs.length} songs',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Fallback placeholder icon widget when no cover art URL is available
  Widget _defaultArt() {
    return Container(
      width: 92,
      height: 92,
      color: const Color(0xFF1A1A2E),
      child: const Icon(Icons.queue_music, color: Color(0xFFB06EF3), size: 34),
    );
  }
}

// Screen that displays the tracks contained in a user-created local playlist
class LocalPlaylistScreen extends StatefulWidget {
  // Name of the playlist as stored in local preferences / database
  final String playlistName;

  const LocalPlaylistScreen({
    super.key,
    required this.playlistName,
  });

  @override
  State<LocalPlaylistScreen> createState() => _LocalPlaylistScreenState();
}

// State management for LocalPlaylistScreen: handles local storage loading, additions, and removals
class _LocalPlaylistScreenState extends State<LocalPlaylistScreen> {
  // Storage service instance used to read and write playlist data
  final _storage = StorageService();
  // Cached list of songs belonging to this local playlist
  List<Song> _songs = [];
  // Tracks whether the playlist songs are currently being loaded from storage
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    // Load playlist songs as soon as the screen is initialized
    _load();
  }

  // Reads songs for this playlist from persistent storage and updates the state
  Future<void> _load() async {
    final playlists = await _storage.getPlaylists();
    if (!mounted) return;
    setState(() {
      _songs = playlists[widget.playlistName] ?? [];
      _loading = false;
    });
  }

  // Removes a song from local storage and also synchronizes deletion with YouTube if connected
  Future<void> _removeSong(Song song) async {
    // First remove the track from local app storage
    await _storage.removeSongFromPlaylist(widget.playlistName, song);
    // Reload local list to update the UI
    await _load();
    if (mounted) {
      final account = context.read<AccountProvider>();
      // If user is authenticated with YouTube and the song came from YouTube, sync removal to cloud
      if (account.hasLiveSession && account.youtubeAuthorized && song.source == 'youtube') {
        final headers = await account.getAuthHeaders();
        if (headers != null) {
          final playlist = await YoutubeAccountService().findPlaylistByName(headers, widget.playlistName);
          if (playlist != null) {
            await YoutubeAccountService().removeSongFromPlaylist(headers, playlist.id, song.id, song.setVideoId);
            // Refresh account library in background to update counts
            unawaited(account.refreshLibrary());
          }
        }
      }
    }
  }

  // Shows a modal bottom sheet with options when a song in the playlist is long-pressed
  void _showSongOptions(BuildContext context, Song song) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF111118),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              // Drag handle bar indicator at top of modal sheet
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              const SizedBox(height: 12),
              // Header showing song thumbnail, title, and artist name
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    // Album art thumbnail with rounded corners
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: song.thumbnailUrl.isNotEmpty
                          ? CachedNetworkImage(
                              imageUrl: song.thumbnailUrl,
                              width: 40,
                              height: 40,
                              fit: BoxFit.cover,
                              errorWidget: (_, __, ___) => const Icon(Icons.music_note, color: Color(0xFFB06EF3)),
                              placeholder: (_, __) => const Icon(Icons.music_note, color: Color(0xFFB06EF3)),
                            )
                          : const Icon(Icons.music_note, color: Color(0xFFB06EF3)),
                    ),
                    const SizedBox(width: 12),
                    // Song title and artist details
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            song.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            song.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(color: Colors.white12),
              // Option to remove the song from this local playlist
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                title: const Text(
                  'Remove from this playlist',
                  style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w600),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _removeSong(song);
                },
              ),
              // Option to add this song to another playlist
              ListTile(
                leading: const Icon(Icons.playlist_add_rounded, color: Colors.white),
                title: const Text(
                  'Add to other playlist',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                ),
                onTap: () {
                  Navigator.pop(context);
                  showAddToPlaylistSheet(context, song);
                },
              ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }

  // Opens a full bottom sheet allowing the user to search for songs and add them to this playlist
  void _openAddSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF111118),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _PlaylistSongSearchSheet(
        playlistName: widget.playlistName,
        onAdded: _load,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Scaffold UI structure with top AppBar, floating Add button, and mini player
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      appBar: AppBar(
        title: Text(
          widget.playlistName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      // Floating button to trigger search sheet for adding new songs
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openAddSheet,
        backgroundColor: const Color(0xFFB06EF3),
        icon: const Icon(Icons.playlist_add_rounded, color: Colors.white),
        label: const Text(
          'Add Songs',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
        ),
      ),
      // Persistent mini player pinned at bottom of screen
      bottomNavigationBar: const SafeArea(child: MiniPlayer()),
      // Display loading spinner, empty placeholder, or list of songs
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFFB06EF3)),
            )
          : _songs.isEmpty
              ? const _PlaylistEmptyMessage(
                  icon: Icons.playlist_add_rounded,
                  title: 'No songs yet',
                  subtitle: 'Use Add Songs to search and fill this playlist.',
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 150, top: 8),
                  itemCount: _songs.length,
                  itemBuilder: (context, index) => SongTile(
                    song: _songs[index],
                    index: index + 1,
                    // Tapping song starts playback with this playlist as queue
                    onTap: () => context
                        .read<PlayerProvider>()
                        .playSong(_songs[index], playlist: _songs),
                    // Long press opens options sheet to remove or add elsewhere
                    onLongPress: () => _showSongOptions(context, _songs[index]),
                  ),
                ),
    );
  }
}

// Bottom sheet widget allowing users to search songs online and add them directly to a local playlist
class _PlaylistSongSearchSheet extends StatefulWidget {
  // Target playlist name to which selected songs will be added
  final String playlistName;
  // Callback invoked after a song is successfully added so the parent list can reload
  final VoidCallback onAdded;

  const _PlaylistSongSearchSheet({
    required this.playlistName,
    required this.onAdded,
  });

  @override
  State<_PlaylistSongSearchSheet> createState() =>
      _PlaylistSongSearchSheetState();
}

// State for _PlaylistSongSearchSheet: manages user query input, network search, and adding songs
class _PlaylistSongSearchSheetState extends State<_PlaylistSongSearchSheet> {
  // Text controller for the search input textfield
  final _controller = TextEditingController();
  // Storage service instance for local playlist data operations
  final _storage = StorageService();
  // List of search result songs returned by the backend API
  List<Song> _results = [];
  // Whether a search request is actively in-flight
  bool _loading = false;

  @override
  void dispose() {
    // Clean up text editing controller when sheet is closed
    _controller.dispose();
    super.dispose();
  }

  // Searches for songs matching the current text query in the text field
  Future<void> _search() async {
    final query = _controller.text.trim();
    if (query.isEmpty) return;
    setState(() => _loading = true);
    // Fetch up to 50 matching songs from the API
    final songs = await ApiService.search(query, limit: 50);
    if (!mounted) return;
    setState(() {
      _results = songs;
      _loading = false;
    });
  }

  // Adds the selected song to local playlist storage and syncs to YouTube if connected
  Future<void> _add(Song song) async {
    // Save song to local SQLite / storage under this playlist name
    await _storage.addSongToPlaylist(widget.playlistName, song);
    // Trigger the parent screen's reload callback
    widget.onAdded();
    if (mounted) {
      final account = context.read<AccountProvider>();
      // If user has an active YouTube session and song is from YouTube, sync with remote playlist
      if (account.hasLiveSession && account.youtubeAuthorized && song.source == 'youtube') {
        final headers = await account.getAuthHeaders();
        if (headers != null) {
          // Ensure playlist exists on YouTube account or create it
          final playlist = await YoutubeAccountService().ensurePlaylist(headers, widget.playlistName);
          if (playlist != null) {
            // Add song to remote YouTube playlist
            final ok = await YoutubeAccountService().addSongToPlaylist(headers, playlist.id, song.id);
            if (ok) {
              account.recordPlaylistSongAddition(playlist.id, song.id);
            }
            // Trigger background library refresh to keep caches consistent
            unawaited(account.refreshLibrary());
          }
        }
      }
    }
    if (!mounted) return;
    // Show a confirmation snackbar notification
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Added ${song.title}'),
        backgroundColor: const Color(0xFF141420),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Modal sheet container respecting keyboard insets and device safe area
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          12,
          16,
          MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.78,
          child: Column(
            children: [
              // Drag handle bar indicator
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              const SizedBox(height: 16),
              // Search input text field with submit trigger and search icon
              TextField(
                controller: _controller,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Search songs to add',
                  hintStyle: const TextStyle(color: Colors.white38),
                  prefixIcon:
                      const Icon(Icons.search, color: Color(0xFFB06EF3)),
                  suffixIcon: IconButton(
                    onPressed: _search,
                    icon:
                        const Icon(Icons.arrow_forward, color: Colors.white70),
                  ),
                  filled: true,
                  fillColor: const Color(0xFF141420),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
                onSubmitted: (_) => _search(),
              ),
              const SizedBox(height: 12),
              // Search results list, loading indicator, or placeholder message
              Expanded(
                child: _loading
                    ? const Center(
                        child:
                            CircularProgressIndicator(color: Color(0xFFB06EF3)),
                      )
                    : _results.isEmpty
                        ? const _PlaylistEmptyMessage(
                            icon: Icons.search,
                            title: 'Search for songs',
                            subtitle: 'Tap a result to add it to the playlist.',
                          )
                        : ListView.builder(
                            itemCount: _results.length,
                            itemBuilder: (context, index) => SongTile(
                              song: _results[index],
                              index: index + 1,
                              // Tapping a result adds it to this playlist
                              onTap: () => _add(_results[index]),
                            ),
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Reusable placeholder widget displayed when a playlist or search list is empty
class _PlaylistEmptyMessage extends StatelessWidget {
  // Icon to display in the center of the placeholder
  final IconData icon;
  // Main title text for the empty state
  final String title;
  // Subtitle providing hints or next actions
  final String subtitle;

  const _PlaylistEmptyMessage({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white24, size: 56),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white38, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
