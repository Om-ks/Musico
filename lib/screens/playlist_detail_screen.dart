import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

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


class RemotePlaylistScreen extends StatefulWidget {
  final MusicPlaylist playlist;

  const RemotePlaylistScreen({
    super.key,
    required this.playlist,
  });

  @override
  State<RemotePlaylistScreen> createState() => _RemotePlaylistScreenState();
}

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

class _RemotePlaylistScreenState extends State<RemotePlaylistScreen> {
  List<Song> _songs = [];
  bool _loading = true;
  bool get _isLikedPlaylist =>
      widget.playlist.id == 'LM' || widget.playlist.id == 'VLLM';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final account = context.read<AccountProvider>();
    List<Song> songs = [];

    final headers = await account.getAuthHeaders() ?? <String, String>{};

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
      try {
        songs = await YoutubeAccountService().fetchPlaylistSongs(
          headers,
          widget.playlist.id,
          album: widget.playlist.title,
        );
      } catch (e) {
        debugPrint('InnerTube playlist fetch failed: $e');
      }

      // Fallback to Data API / Scraper
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

  Future<void> _removeSong(Song song) async {
    setState(() {
      _songs.removeWhere((s) => s.id == song.id);
    });

    final account = context.read<AccountProvider>();
    if (account.hasLiveSession && account.youtubeAuthorized) {
      final headers = await account.getAuthHeaders();
      if (headers != null) {
        final ok = await YoutubeAccountService().removeSongFromPlaylist(
          headers,
          widget.playlist.id,
          song.id,
        );
        if (ok) {
          unawaited(account.refreshLibrary());
        }
      }
    }
  }

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
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
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
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      appBar: AppBar(
        title: Text(
          widget.playlist.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      bottomNavigationBar: const SafeArea(child: MiniPlayer()),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFFB06EF3)),
            )
          : CustomScrollView(
              slivers: [
                SliverToBoxAdapter(child: _remoteHeader()),
                if (_songs.isEmpty)
                  const SliverFillRemaining(
                    child: _PlaylistEmptyMessage(
                      icon: Icons.queue_music_outlined,
                      title: 'No songs loaded',
                      subtitle: 'This playlist may be unavailable right now.',
                    ),
                  )
                else
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) => SongTile(
                        song: _songs[index],
                        index: index + 1,
                        onTap: () => context
                            .read<PlayerProvider>()
                            .playSong(_songs[index], playlist: _songs),
                        onLongPress: () => _showSongOptions(context, _songs[index]),
                      ),
                      childCount: _songs.length,
                    ),
                  ),
                const SliverToBoxAdapter(child: SizedBox(height: 130)),
              ],
            ),
    );
  }

  Widget _remoteHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
      child: Row(
        children: [
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

  Widget _defaultArt() {
    return Container(
      width: 92,
      height: 92,
      color: const Color(0xFF1A1A2E),
      child: const Icon(Icons.queue_music, color: Color(0xFFB06EF3), size: 34),
    );
  }
}

class LocalPlaylistScreen extends StatefulWidget {
  final String playlistName;

  const LocalPlaylistScreen({
    super.key,
    required this.playlistName,
  });

  @override
  State<LocalPlaylistScreen> createState() => _LocalPlaylistScreenState();
}

class _LocalPlaylistScreenState extends State<LocalPlaylistScreen> {
  final _storage = StorageService();
  List<Song> _songs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final playlists = await _storage.getPlaylists();
    if (!mounted) return;
    setState(() {
      _songs = playlists[widget.playlistName] ?? [];
      _loading = false;
    });
  }

  Future<void> _removeSong(Song song) async {
    await _storage.removeSongFromPlaylist(widget.playlistName, song);
    await _load();
    if (mounted) {
      final account = context.read<AccountProvider>();
      if (account.hasLiveSession && account.youtubeAuthorized && song.source == 'youtube') {
        final headers = await account.getAuthHeaders();
        if (headers != null) {
          final playlist = await YoutubeAccountService().findPlaylistByName(headers, widget.playlistName);
          if (playlist != null) {
            await YoutubeAccountService().removeSongFromPlaylist(headers, playlist.id, song.id);
            unawaited(account.refreshLibrary());
          }
        }
      }
    }
  }

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
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
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
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      appBar: AppBar(
        title: Text(
          widget.playlistName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openAddSheet,
        backgroundColor: const Color(0xFFB06EF3),
        icon: const Icon(Icons.playlist_add_rounded, color: Colors.white),
        label: const Text(
          'Add Songs',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
        ),
      ),
      bottomNavigationBar: const SafeArea(child: MiniPlayer()),
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
                    onTap: () => context
                        .read<PlayerProvider>()
                        .playSong(_songs[index], playlist: _songs),
                    onLongPress: () => _showSongOptions(context, _songs[index]),
                  ),
                ),
    );
  }
}

class _PlaylistSongSearchSheet extends StatefulWidget {
  final String playlistName;
  final VoidCallback onAdded;

  const _PlaylistSongSearchSheet({
    required this.playlistName,
    required this.onAdded,
  });

  @override
  State<_PlaylistSongSearchSheet> createState() =>
      _PlaylistSongSearchSheetState();
}

class _PlaylistSongSearchSheetState extends State<_PlaylistSongSearchSheet> {
  final _controller = TextEditingController();
  final _storage = StorageService();
  List<Song> _results = [];
  bool _loading = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _controller.text.trim();
    if (query.isEmpty) return;
    setState(() => _loading = true);
    final songs = await ApiService.search(query, limit: 50);
    if (!mounted) return;
    setState(() {
      _results = songs;
      _loading = false;
    });
  }

  Future<void> _add(Song song) async {
    await _storage.addSongToPlaylist(widget.playlistName, song);
    widget.onAdded();
    if (mounted) {
      final account = context.read<AccountProvider>();
      if (account.hasLiveSession && account.youtubeAuthorized && song.source == 'youtube') {
        final headers = await account.getAuthHeaders();
        if (headers != null) {
          final playlist = await YoutubeAccountService().ensurePlaylist(headers, widget.playlistName);
          if (playlist != null) {
            final ok = await YoutubeAccountService().addSongToPlaylist(headers, playlist.id, song.id);
            if (ok) {
              account.recordPlaylistSongAddition(playlist.id, song.id);
            }
            unawaited(account.refreshLibrary());
          }
        }
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Added ${song.title}'),
        backgroundColor: const Color(0xFF141420),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              const SizedBox(height: 16),
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

class _PlaylistEmptyMessage extends StatelessWidget {
  final IconData icon;
  final String title;
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
