import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:marquee/marquee.dart';
import '../providers/player_provider.dart';
import '../screens/player_screen.dart';

// A floating mini-player widget pinned above the bottom navigation bar.
// Displays the current song thumbnail, marquee title, artist, playback controls,
// and a subtle bottom progress bar. Tapping opens the full-screen PlayerScreen.
class MiniPlayer extends StatelessWidget {
  // Const constructor for the stateless MiniPlayer.
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    // Listen to changes in PlayerProvider (track change, play/pause, buffering, progress).
    return Consumer<PlayerProvider>(
      builder: (_, provider, __) {
        // Hide the mini-player completely when nothing is queued or playing.
        if (provider.currentSong == null) return const SizedBox.shrink();

        final song = provider.currentSong!;
        // Calculate progress percentage between 0.0 and 1.0.
        final progress = provider.duration.inSeconds > 0
            ? (provider.position.inSeconds / provider.duration.inSeconds).clamp(0.0, 1.0)
            : 0.0;
        final isUnknown = provider.duration.inSeconds <= 0;
        // Dynamic subtitle indicating buffering state, error recovery, or track artist.
        final subtitle = provider.isLoading
            ? 'Loading audio...'
            : provider.error == PlayerError.none
                ? song.artist
                : 'Trying another playable source';

        return GestureDetector(
          // Tapping anywhere on the mini-player slides up the full-screen player modal.
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
                      // Song album artwork / thumbnail with rounded corners.
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
                      // Song title & artist text with marquee scrolling for long titles.
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Marquee scrolling text for song title.
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
                            // Subtitle with animated transition between artist name and loading/error states.
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
                      // Previous track button.
                      _controlBtn(
                        Icons.skip_previous_rounded,
                        tooltip: 'Previous',
                        onTap: provider.playPrevious,
                        size: 24,
                      ),
                      // Dynamic Play/Pause button with loading spinner when buffering.
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 160),
                        child: _playPauseBtn(
                          key: ValueKey(
                            '${provider.isLoading}-${provider.isPlaying}',
                          ),
                          provider: provider,
                        ),
                      ),
                      // Next track button.
                      _controlBtn(
                        Icons.skip_next_rounded,
                        tooltip: 'Next',
                        onTap: provider.playNext,
                        size: 24,
                      ),
                      // Close button to stop playback and dismiss mini-player.
                      _controlBtn(
                        Icons.close_rounded,
                        tooltip: 'Close player',
                        onTap: provider.closePlayer,
                        size: 21,
                      ),
                    ],
                  ),
                ),
                // Slim progress bar running along the bottom edge of the mini-player card.
                ClipRRect(
                  borderRadius:
                      const BorderRadius.vertical(bottom: Radius.circular(12)),
                  child: LinearProgressIndicator(
                    value: isUnknown ? null : progress.clamp(0.0, 1.0),
                    backgroundColor: Colors.white10,
                    valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFFB06EF3)),
                    minHeight: 2,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // Builds the play/pause button, displaying a small circular progress spinner when audio is buffering.
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

  // Generic helper for building compact icon buttons (skip previous, skip next, close).
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

  // Placeholder musical note icon displayed if a song thumbnail fails to load or is empty.
  Widget _defaultArt() => Container(
        width: 42,
        height: 42,
        color: const Color(0xFF1A1A2E),
        child: const Icon(Icons.music_note, color: Color(0xFFB06EF3), size: 20),
      );
}

