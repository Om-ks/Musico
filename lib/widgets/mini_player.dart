import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:marquee/marquee.dart';
import '../providers/player_provider.dart';
import '../screens/player_screen.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerProvider>(
      builder: (_, provider, __) {
        if (provider.currentSong == null) return const SizedBox.shrink();

        final song = provider.currentSong!;
        final progress = provider.duration.inSeconds > 0
            ? (provider.position.inSeconds / provider.duration.inSeconds).clamp(0.0, 1.0)
            : 0.0;
        final isUnknown = provider.duration.inSeconds <= 0;
        final subtitle = provider.isLoading
            ? 'Loading audio...'
            : provider.error == PlayerError.none
                ? song.artist
                : 'Trying another playable source';

        return GestureDetector(
          onTap: () => Navigator.push(
            context,
            PageRouteBuilder(
              pageBuilder: (_, __, ___) => const PlayerScreen(),
              transitionsBuilder: (_, anim, __, child) => SlideTransition(
                position: Tween(
                  begin: const Offset(0, 1),
                  end: Offset.zero,
                ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOut)),
                child: child,
              ),
            ),
          ),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF141420),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFB06EF3).withValues(alpha: 0.4)),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFB06EF3).withValues(alpha: 0.05),
                  blurRadius: 10,
                  spreadRadius: 0,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                  child: Row(
                    children: [
                      // Thumbnail
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: song.thumbnailUrl.isNotEmpty
                            ? CachedNetworkImage(
                                imageUrl: song.thumbnailUrl,
                                width: 42,
                                height: 42,
                                fit: BoxFit.cover,
                                errorWidget: (_, __, ___) => _defaultArt(),
                              )
                            : _defaultArt(),
                      ),
                      const SizedBox(width: 10),
                      // Song info
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              height: 18,
                              child: Marquee(
                                text: song.title,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13,
                                ),
                                scrollAxis: Axis.horizontal,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                blankSpace: 40.0,
                                velocity: 30.0,
                                startPadding: 0.0,
                                pauseAfterRound: const Duration(seconds: 2),
                                startAfter: const Duration(seconds: 2),
                              ),
                            ),
                            const SizedBox(height: 2),
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 180),
                              child: SizedBox(
                                height: 16,
                                key: ValueKey(subtitle),
                                child: Marquee(
                                  text: subtitle,
                                  style: TextStyle(
                                    color: provider.error == PlayerError.none
                                        ? Colors.white.withValues(alpha: 0.5)
                                        : const Color(0xFFFF8A80),
                                    fontSize: 11,
                                  ),
                                  scrollAxis: Axis.horizontal,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  blankSpace: 40.0,
                                  velocity: 25.0,
                                  startPadding: 0.0,
                                  pauseAfterRound: const Duration(seconds: 2),
                                  startAfter: const Duration(seconds: 2),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Controls
                      _controlBtn(
                        Icons.skip_previous_rounded,
                        tooltip: 'Previous',
                        onTap: provider.playPrevious,
                        size: 24,
                      ),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 160),
                        child: _playPauseBtn(
                          key: ValueKey(
                            '${provider.isLoading}-${provider.isPlaying}',
                          ),
                          provider: provider,
                        ),
                      ),
                      _controlBtn(
                        Icons.skip_next_rounded,
                        tooltip: 'Next',
                        onTap: provider.playNext,
                        size: 24,
                      ),
                      _controlBtn(
                        Icons.close_rounded,
                        tooltip: 'Close player',
                        onTap: provider.closePlayer,
                        size: 21,
                      ),
                    ],
                  ),
                ),
                // Progress bar
                ClipRRect(
                  borderRadius:
                      const BorderRadius.vertical(bottom: Radius.circular(12)),
                  child: LinearProgressIndicator(
                    value: isUnknown ? null : progress.clamp(0.0, 1.0),
                    backgroundColor: Colors.white10,
                    valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFFB06EF3)),
                    minHeight: 2,
                  ),
                    backgroundColor: Colors.white10,
                    valueColor:
                        const AlwaysStoppedAnimation<Color>(Color(0xFFB06EF3)),
                    minHeight: 3,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _playPauseBtn({
    Key? key,
    required PlayerProvider provider,
  }) {
    return IconButton(
      key: key,
      tooltip: provider.isLoading
          ? 'Loading'
          : provider.isPlaying
              ? 'Pause'
              : 'Play',
      onPressed: provider.isLoading ? null : provider.togglePlayPause,
      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
      padding: EdgeInsets.zero,
      icon: provider.isLoading
          ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                color: Color(0xFFB06EF3),
                strokeWidth: 2.4,
              ),
            )
          : Icon(
              provider.isPlaying
                  ? Icons.pause_rounded
                  : Icons.play_arrow_rounded,
              color: const Color(0xFFB06EF3),
              size: 32,
            ),
    );
  }

  Widget _controlBtn(
    IconData icon, {
    Key? key,
    required String tooltip,
    required VoidCallback onTap,
    required double size,
  }) {
    return IconButton(
      key: key,
      tooltip: tooltip,
      onPressed: onTap,
      constraints: const BoxConstraints.tightFor(width: 36, height: 40),
      padding: EdgeInsets.zero,
      icon: Icon(
        icon,
        color: Colors.white,
        size: size,
      ),
    );
  }

  Widget _defaultArt() => Container(
        width: 42,
        height: 42,
        color: const Color(0xFF1A1A2E),
        child: const Icon(Icons.music_note, color: Color(0xFFB06EF3), size: 20),
      );
}

