import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/song.dart';
import '../models/music_playlist.dart';
import '../providers/player_provider.dart';
import '../services/storage_service.dart';
import '../providers/account_provider.dart';
import '../widgets/song_tile.dart';
import 'playlist_detail_screen.dart';
import '../services/youtube_account_service.dart';

// LibraryScreen is the personal music collection screen.
// It organizes user music into 4 tabs: Liked Songs, Recently Played, Offline Downloads, and Playlists.
class LibraryScreen extends StatefulWidget {
  // Callback invoked when the user taps the top-left hamburger menu icon.
  final VoidCallback? onOpenMenu;

  // Constructor allowing an optional onOpenMenu callback.
  const LibraryScreen({super.key, this.onOpenMenu});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

// State class managing tab switching, local storage loading, and YouTube Music synchronization.
class _LibraryScreenState extends State<LibraryScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  // Controls switching between the 4 library tabs (Liked, Recent, Downloads, Playlists).
  late TabController _tabs;

  // Service to read/write offline songs, liked songs, recent history, and local playlists.
  final _storage = StorageService();

  // In-memory list of songs liked by the user.
  List<Song> _liked = [];

  // In-memory list of recently played songs.
  List<Song> _recent = [];

  // In-memory list of songs downloaded to the device for offline playback.
  List<Song> _downloads = [];

  // Map storing local playlists where key is the playlist name and value is the list of songs.
  Map<String, List<Song>> _playlists = {};

  // Indicates whether initial data loading is in progress (shows a loading indicator).
  bool _loading = true;

  // Cached reference to the PlayerProvider to monitor changes in playback history.
  PlayerProvider? _playerProvider;

  // Tracks the revision number of recent songs to know when new songs were played.
  int _seenRecentRevision = 0;

  // Sets up tabs, registers app lifecycle observer, and triggers the initial data load.
  @override
  void initState() {
    super.initState();
    // 4 tabs: 0 = Liked, 1 = Recent, 2 = Downloads, 3 = Playlists
    _tabs = TabController(length: 4, vsync: this);
    // Listen for app pause/resume events to refresh data when user returns to app
    WidgetsBinding.instance.addObserver(this);
    _tabs.addListener(_handleTabChanged);
    _load();
  }

  // Called when inherited widget dependencies change; binds our listener to PlayerProvider.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final provider = context.read<PlayerProvider>();
    if (_playerProvider == provider) return;

    // Remove old listener if provider reference changed
    _playerProvider?.removeListener(_handlePlayerChanged);
    _playerProvider = provider;
    _seenRecentRevision = provider.recentRevision;
    // Listen for playback updates (e.g. newly played songs)
    provider.addListener(_handlePlayerChanged);
  }

  // Cleans up listeners, tab controller, and lifecycle observers when the screen is removed.
  @override
  void dispose() {
    _playerProvider?.removeListener(_handlePlayerChanged);
    _tabs.removeListener(_handleTabChanged);
    WidgetsBinding.instance.removeObserver(this);
    _tabs.dispose();
    super.dispose();
  }

  // Reloads local music when the user brings the app back to the foreground from the background.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_load(refreshYoutube: false, showSpinner: false));
    }
  }

  // Loads liked songs, recent history, downloads, and playlists from local storage.
  // Also triggers an asynchronous refresh of YouTube Music library if logged in.
  Future<void> _load(
      {bool refreshYoutube = true,
      bool force = false,
      bool showSpinner = true}) async {
    if (showSpinner) {
      setState(() => _loading = true);
    }

    // Refresh YouTube library in the background if the user has signed into their account
    if (refreshYoutube) {
      final account = context.read<AccountProvider>();
      if (account.hasLiveSession && account.youtubeAuthorized) {
        unawaited(account.refreshLibrary(force: force));
      }
    }

    // Retrieve local data from SQLite/preferences storage
    final localLiked = await _storage.getLikedSongs();
    final localRecent = await _storage.getRecentlyPlayed();
    final localDownloads = await _storage.getDownloadedSongs();
    final localPlaylists = await _storage.getPlaylists();

    if (mounted) {
      setState(() {
        _liked = localLiked;
        _recent = localRecent;
        _downloads = localDownloads;
        _playlists = localPlaylists;
        _loading = false;
      });
    }
  }

  // Called whenever PlayerProvider notifies listeners.
  // If the recently played revision has changed, refreshes the recent songs list without showing a spinner.
  void _handlePlayerChanged() {
    final provider = _playerProvider;
    if (provider == null) return;

    final revision = provider.recentRevision;
    // Only refresh if new songs were actually played
    if (revision == _seenRecentRevision) return;

    _seenRecentRevision = revision;
    unawaited(_load(refreshYoutube: false, showSpinner: false));
  }

  // Listens for tab index changes; automatically refreshes the "Recent" list when that tab is opened.
  void _handleTabChanged() {
    if (!_tabs.indexIsChanging && _tabs.index == 1) {
      unawaited(_loadRecent());
    }
  }

  // Fetches the latest recently played songs list from local storage.
  Future<void> _loadRecent() async {
    final recent = await _storage.getRecentlyPlayed();
    if (!mounted) return;
    setState(() => _recent = recent);
  }

  // Builds the library screen layout including the top app bar with tabs and the TabBarView.
  @override
  Widget build(BuildContext context) {
    // Access the YouTube account provider to display online liked songs & playlists
    final account = context.watch<AccountProvider>();
    final ytLib = account.library;

    // Merge YouTube online liked songs with local offline liked songs, avoiding duplicates
    final combinedLiked = ytLib.likedSongs.isNotEmpty
        ? [...ytLib.likedSongs, ..._liked.where((s) => !ytLib.likedSongs.any((ys) => ys.id == s.id))]
        : _liked;

    // Deduplicate recently played songs from local and YouTube sources
    final combinedRecent = _dedupeSongs([..._recent, ...ytLib.recentSongs]);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.menu_rounded, color: Colors.white70),
          onPressed: widget.onOpenMenu,
        ),
        title: Text('Library',
            style: GoogleFonts.spaceGrotesk(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w800)),
        // Tab bar to navigate between the 4 library sections
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          indicatorColor: const Color(0xFFB06EF3),
          labelColor: const Color(0xFFB06EF3),
          unselectedLabelColor: Colors.white38,
          labelStyle:
              const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          tabs: const [
            Tab(text: 'Liked'),
            Tab(text: 'Recent'),
            Tab(text: 'Downloads'),
            Tab(text: 'Playlists'),
          ],
        ),
        actions: [
          // Manual refresh button to re-fetch library items and sync with YouTube
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white70),
            onPressed: () => _load(refreshYoutube: true, force: true),
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFFB06EF3)))
          : TabBarView(
              controller: _tabs,
              children: [
                _likedTab(combinedLiked),
                _recentTab(combinedRecent),
                _downloadsTab(),
                _playlistsTab(ytLib.playlists),
              ],
            ),
    );
  }

  // Helper method to remove duplicate songs based on their unique source and ID key.
  List<Song> _dedupeSongs(List<Song> songs) {
    final seen = <String>{};
    return songs.where((s) => seen.add('${s.source}:${s.id}')).toList();
  }

  // ── Liked songs tab ────────────────────────────────────────────────────────

  // Builds the view for liked songs. If the list is empty, shows a friendly empty state.
  Widget _likedTab(List<Song> songs) {
    if (songs.isEmpty) {
      return _emptyState(Icons.favorite_border, 'No liked songs yet',
          'Tap the heart in the player to like songs');
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 160),
      itemCount: songs.length,
      itemBuilder: (ctx, i) => SongTile(
        song: songs[i],
        // Tapping plays this song and queues the rest of the liked songs
        onTap: () =>
            context.read<PlayerProvider>().playSong(songs[i], playlist: songs),
        // Allows removing the song from YouTube Music likes if signed in
        onRemove: () async {
          final account = context.read<AccountProvider>();
          if (account.hasLiveSession && account.youtubeAuthorized) {
            final headers = await account.getAuthHeaders();
            if (headers != null) {
              await YoutubeAccountService().rateSong(headers, songs[i].id, 'none');
              account.toggleLocalLikedState(songs[i], false);
              _load(refreshYoutube: true, force: true);
            }
          }
        },
      ),
    );
  }

  // ── Recently played tab ────────────────────────────────────────────────────

  // Builds the view for recently played songs.
  Widget _recentTab(List<Song> songs) {
    if (songs.isEmpty) {
      return _emptyState(Icons.history, 'Nothing played yet',
          'Songs you play will appear here');
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 160),
      itemCount: songs.length,
      itemBuilder: (ctx, i) => SongTile(
        song: songs[i],
        // Tapping plays the song and queues the recent list
        onTap: () =>
            context.read<PlayerProvider>().playSong(songs[i], playlist: songs),
        // Removing a song clears it from local playback history
        onRemove: () async {
          await context.read<PlayerProvider>().removeFromRecentlyPlayed(songs[i]);
          _loadRecent();
        },
      ),
    );
  }

  // ── Offline Downloads tab ──────────────────────────────────────────────────

  // Builds the view for songs downloaded to local storage for offline playback.
  Widget _downloadsTab() {
    if (_downloads.isEmpty) {
      return _emptyState(
        Icons.download_outlined,
        'No downloads yet',
        'Tap the download button on a song to save it offline',
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 160),
      itemCount: _downloads.length,
      itemBuilder: (ctx, i) => SongTile(
        song: _downloads[i],
        // Tapping plays the offline audio file
        onTap: () => context
            .read<PlayerProvider>()
            .playSong(_downloads[i], playlist: _downloads),
        // Long pressing prompts or triggers deleting the offline download
        onLongPress: () async {
          await context.read<PlayerProvider>().removeDownload(_downloads[i]);
          _load();
        },
      ),
    );
  }

  // ── Playlists tab ─────────────────────────────────────────────────────────

  // Builds the view for user playlists (both YouTube Music playlists and locally created ones).
  // Includes a floating action button to create new playlists.
  Widget _playlistsTab(List<dynamic> ytPlaylists) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 160),
        child: FloatingActionButton.extended(
          onPressed: _createPlaylistDialog,
          backgroundColor: const Color(0xFFB06EF3),
          icon: const Icon(Icons.add, color: Colors.white),
          label: const Text('New Playlist',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        ),
      ),
      body: (_playlists.isEmpty && ytPlaylists.isEmpty)
          ? _emptyState(Icons.queue_music, 'No playlists yet',
              'Create a playlist to organise your music')
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 160),
              children: [
                // Render YouTube playlists
                ...ytPlaylists.map((playlist) {
                  return _playlistCard(
                    title: playlist.title,
                    subtitle: playlist.itemCount > 0 ? '${playlist.itemCount} songs' : 'YouTube Playlist',
                    isYoutube: true,
                    onRename: () => _renamePlaylistDialog(playlist.title, true, playlist.id),
                    onDelete: () async {
                      final account = context.read<AccountProvider>();
                      if (account.hasLiveSession && account.youtubeAuthorized) {
                        final headers = await account.getAuthHeaders();
                        if (headers != null) {
                          final success = await YoutubeAccountService().deletePlaylist(headers, playlist.id);
                          if (success) {
                            account.removePlaylistOptimistic(playlist.id, playlist.title);
                          }
                        }
                      }
                    },
                    onTap: () {
                      // Navigate to YouTube Playlist detail screen
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => PlaylistDetailScreen(
                            playlistId: playlist.id,
                            playlistTitle: playlist.title,
                            playlistOwner: playlist.owner,
                            thumbnailUrl: playlist.thumbnailUrl,
                          ),
                        ),
                      );
                    },
                  );
                }),
              ],
            ),
    );
  }

  // Renders an individual playlist card tile with actions to tap, rename, and delete.
  Widget _playlistCard({
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    VoidCallback? onDelete,
    VoidCallback? onRename,
    bool isYoutube = false,
  }) {
    return Card(
      color: const Color(0xFF141420),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        // Leading square icon with red gradient for YouTube playlists or purple for local playlists
        leading: Container(
          width: 50,
          height: 50,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            gradient: LinearGradient(
              colors: isYoutube
                  ? [const Color(0xFFFF0000), const Color(0xFFB06EF3)]
                  : [const Color(0xFFB06EF3), const Color(0xFF6E9EF3)],
            ),
          ),
          child: Icon(isYoutube ? Icons.subscriptions : Icons.queue_music,
              color: Colors.white, size: 26),
        ),
        title: Text(title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 15)),
        subtitle: Text(subtitle,
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5), fontSize: 12)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Optional rename button (pencil icon)
            if (onRename != null)
              IconButton(
                icon: const Icon(Icons.edit_outlined, color: Colors.white38),
                onPressed: onRename,
              ),
            // Optional delete button (trash can icon) with confirmation alert
            if (onDelete != null)
              IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.white38),
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      backgroundColor: const Color(0xFF1A1A2E),
                      title: const Text('Delete Playlist?', style: TextStyle(color: Colors.white)),
                      content: Text('Are you sure you want to delete \'$title\'?', style: const TextStyle(color: Colors.white70)),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Cancel', style: TextStyle(color: Colors.white38)),
                        ),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                          onPressed: () {
                            Navigator.pop(ctx);
                            onDelete();
                          },
                          child: const Text('Delete', style: TextStyle(color: Colors.white)),
                        ),
                      ],
                    ),
                  );
                },
              )
            else
              const Icon(Icons.chevron_right, color: Colors.white24),
          ],
        ),
        onTap: onTap,
        // Long pressing the card also offers deletion
        onLongPress: () {
          if (onDelete != null) {
            showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                backgroundColor: const Color(0xFF1A1A2E),
                title: const Text('Delete Playlist?', style: TextStyle(color: Colors.white)),
                content: Text('Are you sure you want to delete \'$title\'?', style: const TextStyle(color: Colors.white70)),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancel', style: TextStyle(color: Colors.white38)),
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                    onPressed: () {
                      Navigator.pop(ctx);
                      onDelete();
                    },
                    child: const Text('Delete', style: TextStyle(color: Colors.white)),
                  ),
                ],
              ),
            );
          }
        },
      ),
    );
  }

  // Opens a dialog prompting the user for a new name to rename an existing playlist.
  void _renamePlaylistDialog(String oldName, bool isYoutube, String ytId) {
    final ctrl = TextEditingController(text: oldName);
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('Rename Playlist', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'New playlist name',
            hintStyle: TextStyle(color: Colors.white38),
            enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: Color(0xFFB06EF3))),
            focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: Color(0xFFB06EF3), width: 2)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFB06EF3)),
            onPressed: () async {
              final newName = ctrl.text.trim();
              if (newName.isNotEmpty && newName != oldName) {
                if (isYoutube) {
                  // Rename online on YouTube Music
                  final account = context.read<AccountProvider>();
                  if (account.youtubeAuthorized) {
                      final headers = await account.getAuthHeaders();
                      if (headers != null) {
                        account.updatePlaylistNameOptimistic(ytId, newName);
                        await YoutubeAccountService().editPlaylist(headers, ytId, newName);
                      }
                    }
                } else {
                  // Rename in local device storage
                  await _storage.renamePlaylist(oldName, newName);
                  _load();
                }
              }
              if (mounted) Navigator.pop(dialogContext);
            },
            child: const Text('Rename', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  // Opens a dialog prompting the user to type a name and create a new playlist.
  void _createPlaylistDialog() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title:
            const Text('New Playlist', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Playlist name',
            hintStyle: TextStyle(color: Colors.white38),
            enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: Color(0xFFB06EF3))),
            focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: Color(0xFFB06EF3))),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child:
                const Text('Cancel', style: TextStyle(color: Colors.white38)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFB06EF3)),
            onPressed: () async {
              final name = ctrl.text.trim();
              if (name.isNotEmpty) {
                // Save new playlist to local device storage
                await _storage.createPlaylist(name);
                if (mounted) {
                  final account = context.read<AccountProvider>();
                  // If logged into YouTube Music, create the playlist there as well
                  if (account.hasLiveSession && account.youtubeAuthorized) {
                    final headers = await account.getAuthHeaders();
                    if (headers != null) {
                      final newId = await YoutubeAccountService().createPlaylist(headers, name);
                      if (newId != null) {
                        account.addPlaylistOptimistic(MusicPlaylist(id: newId, title: name, owner: '', thumbnailUrl: '', itemCount: 0, source: 'youtube'));
                      }
                      unawaited(account.refreshLibrary(force: true));
                    }
                  }
                }
                if (!mounted) return;
                Navigator.pop(dialogContext);
                _load();
              }
            },
            child: const Text('Create', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  // Helper widget to render a clean empty state message when a tab has no content yet.
  Widget _emptyState(IconData icon, String title, String sub) {
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
          Text(sub,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white30, fontSize: 13)),
        ],
      ),
    );
  }
}
