import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../models/music_playlist.dart';
import '../services/storage_service.dart';
import '../services/youtube_account_service.dart';
import '../providers/account_provider.dart';

// Displays a modern modal bottom sheet that allows the user to add a song to either
// a local offline playlist or their authenticated YouTube Music account playlists.
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

// Internal StatefulWidget representing the interactive content inside the bottom sheet.
class _AddToPlaylistSheet extends StatefulWidget {
  // The track that will be added to the selected playlist.
  final Song song;

  // Optional notification callback triggered after the song is successfully added.
  final VoidCallback? onChanged;

  // Constructor requiring the target song and optional onChanged callback.
  const _AddToPlaylistSheet({
    required this.song,
    this.onChanged,
  });

  @override
  State<_AddToPlaylistSheet> createState() => _AddToPlaylistSheetState();
}

// State class managing local storage playlists and remote YouTube playlists.
class _AddToPlaylistSheetState extends State<_AddToPlaylistSheet> {
  // Local storage service to retrieve and update user playlists on the device.
  final _storage = StorageService();

  // YouTube account service to interact with online YouTube Music playlists.
  final _youtube = YoutubeAccountService();

  // Map of local playlist names to their constituent songs.
  Map<String, List<Song>> _localPlaylists = {};

  // List of online playlists fetched from the user's logged-in YouTube account.
  List<MusicPlaylist> _ytPlaylists = [];

  // Flag indicating whether playlists are currently being loaded from storage and account.
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    // Load local and YouTube playlists when the sheet opens.
    _load();
  }

  // Fetches local playlists from SharedPreferences and YouTube playlists from AccountProvider.
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

  // Prompts the user with a dialog to enter a new playlist name, then creates it
  // both locally and on YouTube (if the user is currently signed in).
  Future<void> _createPlaylist() async {
    final controller = TextEditingController();
    // Show a dialog with a text input field for the playlist name.
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

    // If user canceled the dialog or submitted blank text, abort.
    if (name == null || name.isEmpty) return;
    
    // Create locally in device storage and immediately add the song to it.
    await _storage.createPlaylist(name);
    await _storage.addSongToPlaylist(name, widget.song);
    
    widget.onChanged?.call();
    if (mounted) Navigator.pop(context);

    // Optionally create on YouTube if the user is authenticated and the song is from YouTube.
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

  // Adds the song to a local playlist in SharedPreferences, invokes the callback, and dismisses the sheet.
  Future<void> _addToLocal(String playlistName) async {
    await _storage.addSongToPlaylist(playlistName, widget.song);
    widget.onChanged?.call();
    if (!mounted) return;
    Navigator.pop(context);
  }

  // Adds the song to a remote YouTube Music playlist using OAuth/cookie credentials in the background.
  Future<void> _addToYoutube(MusicPlaylist playlist) async {
    final account = context.read<AccountProvider>();
    widget.onChanged?.call();
    if (mounted) Navigator.pop(context);

    // Run YouTube API update asynchronously without blocking the UI.
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

  // Builds the visual UI of the bottom sheet containing drag pill, header, and playlist lists.
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
              // Top pill handle indicating that the modal sheet is draggable/dismissible.
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
              // Header displaying the title of the song being added.
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
              // Show circular loading indicator while playlists are being fetched.
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
                      // Tile button allowing the user to create a new playlist from scratch.
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
                      // Section for local offline playlists stored in SharedPreferences.
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
                      // Section for remote cloud playlists linked to user's YouTube account.
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
                              playlist.itemCount > 0 ? '${playlist.itemCount} songs • YouTube' : 'YouTube',
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
