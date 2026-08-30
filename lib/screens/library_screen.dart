import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../services/storage_service.dart';
import '../providers/account_provider.dart';
import '../widgets/song_tile.dart';
import 'playlist_detail_screen.dart';
import '../services/youtube_account_service.dart';

class LibraryScreen extends StatefulWidget {
  final VoidCallback? onOpenMenu;

  const LibraryScreen({super.key, this.onOpenMenu});
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late TabController _tabs;
  final _storage = StorageService();

  List<Song> _liked = [];
  List<Song> _recent = [];
  List<Song> _downloads = [];
  Map<String, List<Song>> _playlists = {};
  bool _loading = true;
  PlayerProvider? _playerProvider;
  int _seenRecentRevision = 0;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this);
    WidgetsBinding.instance.addObserver(this);
    _tabs.addListener(_handleTabChanged);
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final provider = context.read<PlayerProvider>();
    if (_playerProvider == provider) return;

    _playerProvider?.removeListener(_handlePlayerChanged);
    _playerProvider = provider;
    _seenRecentRevision = provider.recentRevision;
    provider.addListener(_handlePlayerChanged);
  }

  @override
  void dispose() {
    _playerProvider?.removeListener(_handlePlayerChanged);
    _tabs.removeListener(_handleTabChanged);
    WidgetsBinding.instance.removeObserver(this);
    _tabs.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_load(refreshYoutube: false));
    }
  }

  Future<void> _load(
      {bool refreshYoutube = true,
      bool force = false,
      bool showSpinner = true}) async {
    if (showSpinner) {
      setState(() => _loading = true);
    }

    // Refresh YouTube library if signed in and requested
    if (refreshYoutube) {
      final account = context.read<AccountProvider>();
      if (account.hasLiveSession && account.youtubeAuthorized) {
        unawaited(account.refreshLibrary(force: force));
      }
    }

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

  void _handlePlayerChanged() {
    final provider = _playerProvider;
    if (provider == null) return;

    final revision = provider.recentRevision;
    if (revision == _seenRecentRevision) return;

    _seenRecentRevision = revision;
    unawaited(_load(refreshYoutube: false, showSpinner: false));
  }

  void _handleTabChanged() {
    if (!_tabs.indexIsChanging && _tabs.index == 1) {
      unawaited(_loadRecent());
    }
  }

  Future<void> _loadRecent() async {
    final recent = await _storage.getRecentlyPlayed();
    if (!mounted) return;
    setState(() => _recent = recent);
  }

  @override
  Widget build(BuildContext context) {
    final account = context.watch<AccountProvider>();
    final ytLib = account.library;

    final combinedLiked = ytLib.likedSongs.isNotEmpty
        ? _dedupeSongs([...ytLib.likedSongs, ..._liked])
        : _liked;
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

  List<Song> _dedupeSongs(List<Song> songs) {
    final seen = <String>{};
    return songs.where((s) => seen.add('${s.source}:${s.id}')).toList();
  }

  // Liked songs

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
        onTap: () =>
            context.read<PlayerProvider>().playSong(songs[i], playlist: songs),
      ),
    );
  }

  // Recently played

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
        onTap: () =>
            context.read<PlayerProvider>().playSong(songs[i], playlist: songs),
        onRemove: () async {
          await context.read<PlayerProvider>().removeFromRecentlyPlayed(songs[i]);
          _loadRecent();
        },
      ),
    );
  }

  // Playlists

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
        onTap: () => context
            .read<PlayerProvider>()
            .playSong(_downloads[i], playlist: _downloads),
        onLongPress: () async {
          await context.read<PlayerProvider>().removeDownload(_downloads[i]);
          _load();
        },
      ),
    );
  }

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
                ...ytPlaylists.map((playlist) {
                  return _playlistCard(
                    title: playlist.title,
                    subtitle: '${playlist.itemCount} songs • YouTube',
                    isYoutube: true,
                    onRename: () => _renamePlaylistDialog(playlist.title, true, playlist.id),
                    onDelete: () async {
                      final account = context.read<AccountProvider>();
                      if (account.hasLiveSession && account.youtubeAuthorized) {
                        final headers = await account.getAuthHeaders();
                        if (headers != null) {
                          await YoutubeAccountService().deletePlaylist(headers, playlist.id);
                          account.refreshLibrary();
                          _load();
                        }
                      }
                    },
                    onTap: () {
                      // Navigate to YouTube Playlist detail
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
            if (onRename != null)
              IconButton(
                icon: const Icon(Icons.edit_outlined, color: Colors.white38),
                onPressed: onRename,
              ),
            if (onDelete != null)
              IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.white38),
                onPressed: onDelete,
              )
            else
              const Icon(Icons.chevron_right, color: Colors.white24),
          ],
        ),
        onTap: onTap,
      ),
    );
  }

  void _renamePlaylistDialog(String oldName, bool isYoutube, String ytId) {
    final ctrl = TextEditingController(text: oldName);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
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
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFB06EF3)),
            onPressed: () async {
              final newName = ctrl.text.trim();
              if (newName.isNotEmpty && newName != oldName) {
                if (isYoutube) {
                  final account = context.read<AccountProvider>();
                  if (account.youtubeAuthorized) {
                    final headers = await account.getAuthHeaders();
                    if (headers != null) {
                      await YoutubeAccountService().editPlaylist(headers, ytId, newName);
                      unawaited(account.refreshLibrary(force: true));
                    }
                  }
                } else {
                  await _storage.renamePlaylist(oldName, newName);
                  _load();
                }
              }
              if (mounted) Navigator.pop(context);
            },
            child: const Text('Rename'),
          ),
        ],
      ),
    );
  }

  void _createPlaylistDialog() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
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
            onPressed: () => Navigator.pop(context),
            child:
                const Text('Cancel', style: TextStyle(color: Colors.white38)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFB06EF3)),
            onPressed: () async {
              final name = ctrl.text.trim();
              if (name.isNotEmpty) {
                await _storage.createPlaylist(name);
                if (mounted) {
                  final account = context.read<AccountProvider>();
                  if (account.hasLiveSession && account.youtubeAuthorized) {
                    final headers = await account.getAuthHeaders();
                    if (headers != null) {
                      await YoutubeAccountService()
                          .createPlaylist(headers, name);
                      unawaited(account.refreshLibrary());
                    }
                  }
                }
                if (!mounted) return;
                Navigator.pop(context);
                _load();
              }
            },
            child: const Text('Create', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

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
