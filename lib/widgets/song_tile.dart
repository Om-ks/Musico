import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import 'add_to_playlist_sheet.dart';
class SongTile extends StatelessWidget {
  final Song song;
  final VoidCallback onTap;
  final int? index;
  final VoidCallback? onLongPress;
  final VoidCallback? onRemove;

  const SongTile({
    super.key,
    required this.song,
    required this.onTap,
    this.index,
    this.onLongPress,
    this.onRemove,
  });

  String _formatSeconds(int totalSeconds) {
    if (totalSeconds <= 0) return '0:00';
    final int minutes = totalSeconds ~/ 60;
    final int seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Selector<PlayerProvider, _SongTilePlaybackState>(
      selector: (_, provider) => _SongTilePlaybackState(
        currentSongId: provider.currentSong?.id,
        currentSongSource: provider.currentSong?.source,
        isPlaying: provider.isPlaying,
      ),
      builder: (_, playback, __) {
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
          trailing: onRemove != null
              ? IconButton(
                  icon: const Icon(Icons.close, color: Colors.white38, size: 20),
                  onPressed: onRemove,
                )
              : Text(
                  _formatSeconds(song.duration),
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                  ),
                ),
        );
      },
    );
  }

  Widget _thumbnail(bool isCurrent, bool isPlaying) {
    return Stack(
      alignment: Alignment.center,
      children: [
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

  Widget _defaultThumb() {
    return Container(
      width: 48,
      height: 48,
      color: const Color(0xFF1A1A2E),
      child: const Icon(Icons.music_note, color: Color(0xFFB06EF3)),
    );
  }
}

class _SongTilePlaybackState {
  final String? currentSongId;
  final String? currentSongSource;
  final bool isPlaying;

  const _SongTilePlaybackState({
    required this.currentSongId,
    required this.currentSongSource,
    required this.isPlaying,
  });

  @override
  bool operator ==(Object other) {
    return other is _SongTilePlaybackState &&
        other.currentSongId == currentSongId &&
        other.currentSongSource == currentSongSource &&
        other.isPlaying == isPlaying;
  }

  @override
  int get hashCode => Object.hash(
        currentSongId,
        currentSongSource,
        isPlaying,
      );
}
