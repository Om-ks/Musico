import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/account_provider.dart';
import 'add_to_playlist_sheet.dart';
// A reusable list tile widget that displays a song row with its thumbnail, title, artist,
// duration, favorite indicator, and optional removal button.
class SongTile extends StatelessWidget {
  // The song model data displayed by this tile.
  final Song song;

  // Callback triggered when the user taps on this song tile to play it.
  final VoidCallback onTap;

  // Optional zero-based track index within a playlist or queue.
  final int? index;

  // Optional callback triggered on long-press (defaults to showing the "Add to Playlist" sheet).
  final VoidCallback? onLongPress;

  // Optional callback to remove the song from a playlist or history list.
  final VoidCallback? onRemove;

  // Constructor requiring the song data and tap callback.
  const SongTile({
    super.key,
    required this.song,
    required this.onTap,
    this.index,
    this.onLongPress,
    this.onRemove,
  });

  // Converts duration in total seconds into a user-friendly string (e.g., "3:45" or "1:05:20").
  String _formatSeconds(int totalSeconds) {
    if (totalSeconds <= 0) return '0:00';
    final int hours = totalSeconds ~/ 3600;
    final int minutes = (totalSeconds % 3600) ~/ 60;
    final int seconds = totalSeconds % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    // Select only relevant playback fields to prevent rebuilding every tile on position changes.
    return Selector<PlayerProvider, _SongTilePlaybackState>(
      selector: (_, provider) => _SongTilePlaybackState(
        currentSongId: provider.currentSong?.id,
        currentSongSource: provider.currentSong?.source,
        isPlaying: provider.isPlaying,
      ),
      builder: (_, playback, __) {
        // Highlight tile if this song is the one currently loaded in the player.
        final isCurrent = playback.currentSongId == song.id &&
            playback.currentSongSource == song.source;
        return ListTile(
          onTap: onTap,
          onLongPress:
              onLongPress ?? () => showAddToPlaylistSheet(context, song),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          leading: _thumbnail(isCurrent, playback.isPlaying),
          title: Text(
            song.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              // Highlight the active playing song with accent purple text.
              color: isCurrent ? const Color(0xFFB06EF3) : Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
          subtitle: Text(
            song.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
            ),
          ),
          // Trailing widget showing favorite heart, track duration, and optional delete button.
          trailing: Selector<AccountProvider, bool>(
            selector: (_, account) => account.library.likedSongs.any((s) => s.id == song.id),
            builder: (_, isLiked, __) {
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Show small heart icon if the song is liked.
                  if (isLiked)
                    const Padding(
                      padding: EdgeInsets.only(right: 6),
                      child: Icon(Icons.favorite, color: Color(0xFFB06EF3), size: 16),
                    ),
                  // Track duration.
                  Text(
                    _formatSeconds(song.duration),
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                    ),
                  ),
                  // Optional close/remove button.
                  if (onRemove != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: IconButton(
                        icon: const Icon(Icons.close, color: Colors.white38, size: 20),
                        onPressed: onRemove,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  // Builds the thumbnail image with a semi-transparent play/pause overlay icon when active.
  Widget _thumbnail(bool isCurrent, bool isPlaying) {
    return Stack(
      alignment: Alignment.center,
      children: [
        // Rounded track thumbnail loaded from network.
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: song.thumbnailUrl.isNotEmpty
              ? CachedNetworkImage(
                  imageUrl: song.thumbnailUrl,
                  width: 48,
                  height: 48,
                  fit: BoxFit.cover,
                  placeholder: (_, __) => _defaultThumb(),
                  errorWidget: (_, __, ___) => _defaultThumb(),
                )
              : _defaultThumb(),
        ),
        // Dark translucent overlay showing play or pause icon if this track is currently active.
        if (isCurrent)
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: Colors.black.withValues(alpha: 0.5),
            ),
            child: Icon(
              isPlaying ? Icons.pause : Icons.play_arrow,
              color: const Color(0xFFB06EF3),
            ),
          ),
      ],
    );
  }

  // Fallback widget with a musical note icon when no thumbnail is available.
  Widget _defaultThumb() {
    return Container(
      width: 48,
      height: 48,
      color: const Color(0xFF1A1A2E),
      child: const Icon(Icons.music_note, color: Color(0xFFB06EF3)),
    );
  }
}

// Immutable helper class holding state used by the Selector to determine if this tile is currently playing.
class _SongTilePlaybackState {
  // ID of the currently playing track in PlayerProvider.
  final String? currentSongId;

  // Source (e.g. 'youtube') of the currently playing track.
  final String? currentSongSource;

  // Whether audio playback is actively playing (true) or paused (false).
  final bool isPlaying;

  // Constructor requiring the playback state snapshot.
  const _SongTilePlaybackState({
    required this.currentSongId,
    required this.currentSongSource,
    required this.isPlaying,
  });

  // Value equality comparison for Selector optimization.
  @override
  bool operator ==(Object other) {
    return other is _SongTilePlaybackState &&
        other.currentSongId == currentSongId &&
        other.currentSongSource == currentSongSource &&
        other.isPlaying == isPlaying;
  }

  // Hash code implementation consistent with operator ==.
  @override
  int get hashCode => Object.hash(
        currentSongId,
        currentSongSource,
        isPlaying,
      );
}
