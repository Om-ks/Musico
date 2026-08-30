import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../models/music_playlist.dart';
import '../services/storage_service.dart';
import '../services/youtube_account_service.dart';
import '../providers/account_provider.dart';

Future<void> showAddToPlaylistSheet(
  BuildContext context,
  Song song, {
  VoidCallback? onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF111118),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _AddToPlaylistSheet(song: song, onChanged: onChanged),
  );
}

class _AddToPlaylistSheet extends StatefulWidget {
  final Song song;
  final VoidCallback? onChanged;

  const _AddToPlaylistSheet({
    required this.song,
    this.onChanged,
  });

  @override
  State<_AddToPlaylistSheet> createState() => _AddToPlaylistSheetState();
}

class _AddToPlaylistSheetState extends State<_AddToPlaylistSheet> {
  final _storage = StorageService();
  final _youtube = YoutubeAccountService();
  Map<String, List<Song>> _localPlaylists = {};
  List<MusicPlaylist> _ytPlaylists = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final account = context.read<AccountProvider>();
    final local = await _storage.getPlaylists();
    if (!mounted) return;
    setState(() {
      _localPlaylists = local;
      _ytPlaylists = account.library.playlists;
      _loading = false;
    });
  }

  Future<void> _createPlaylist() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title:
            const Text('New Playlist', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Playlist name',
            hintStyle: TextStyle(color: Colors.white38),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Color(0xFFB06EF3)),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Color(0xFFB06EF3)),
            ),
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
              backgroundColor: const Color(0xFFB06EF3),
            ),
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Create', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (name == null || name.isEmpty) return;
    
    // Create locally
    await _storage.createPlaylist(name);
    await _storage.addSongToPlaylist(name, widget.song);
    
    widget.onChanged?.call();
    if (mounted) Navigator.pop(context);

    // Optionally create on YouTube if signed in
    if (mounted) {
      final account = context.read<AccountProvider>();
      if (account.hasLiveSession && account.youtubeAuthorized && widget.song.source == 'youtube') {
        unawaited(() async {
          final headers = await account.getAuthHeaders();
          if (headers != null) {
            final ytId = await _youtube.createPlaylist(headers, name);
            if (ytId != null) {
              final ok = await _youtube.addSongToPlaylist(headers, ytId, widget.song.id);
              if (ok) {
                account.recordPlaylistSongAddition(ytId, widget.song.id);
              }
              unawaited(account.refreshLibrary());
            }
          }
        }());
      }
    }
  }

  Future<void> _addToLocal(String playlistName) async {
    await _storage.addSongToPlaylist(playlistName, widget.song);
    widget.onChanged?.call();
    if (!mounted) return;
    Navigator.pop(context);
  }

  Future<void> _addToYoutube(MusicPlaylist playlist) async {
    final account = context.read<AccountProvider>();
    widget.onChanged?.call();
    if (mounted) Navigator.pop(context);

    if (account.hasLiveSession && account.youtubeAuthorized && widget.song.source == 'youtube') {
      unawaited(() async {
        final headers = await account.getAuthHeaders();
        if (headers != null) {
          final ok = await _youtube.addSongToPlaylist(headers, playlist.id, widget.song.id);
          if (ok) {
            account.recordPlaylistSongAddition(playlist.id, widget.song.id);
            unawaited(account.refreshLibrary());
          }
        }
      }());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(top: 12),
      decoration: const BoxDecoration(
        color: Color(0xFF111118),
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  const Icon(Icons.playlist_add_rounded,
                      color: Color(0xFFB06EF3)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Add "${widget.song.title}"',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(
                    child: CircularProgressIndicator(color: Color(0xFFB06EF3)),
                  ),
                )
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading:
                            const Icon(Icons.add_circle_outline, color: Colors.white70),
                        title: const Text(
                          'Create new playlist',
                          style: TextStyle(
                              color: Colors.white, fontWeight: FontWeight.w700),
                        ),
                        onTap: _createPlaylist,
                      ),
                      if (_localPlaylists.isNotEmpty) ...[
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Text('LOCAL PLAYLISTS', 
                            style: TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1)),
                        ),
                        ..._localPlaylists.entries.map(
                          (entry) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading:
                                const Icon(Icons.queue_music, color: Color(0xFF6EF3E9)),
                            title: Text(
                              entry.key,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle: Text(
                              '${entry.value.length} songs',
                              style: const TextStyle(color: Colors.white38),
                            ),
                            onTap: () => _addToLocal(entry.key),
                          ),
                        ),
                      ],
                      if (_ytPlaylists.isNotEmpty) ...[
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Text('YOUTUBE PLAYLISTS', 
                            style: TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1)),
                        ),
                        ..._ytPlaylists.map(
                          (playlist) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading:
                                const Icon(Icons.subscriptions_rounded, color: Color(0xFFFF0000)),
                            title: Text(
                              playlist.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle: Text(
                              '${playlist.itemCount} songs • YouTube',
                              style: const TextStyle(color: Colors.white38),
                            ),
                            onTap: () => _addToYoutube(playlist),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
