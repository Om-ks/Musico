import 'dart:async';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:google_fonts/google_fonts.dart';
import '../providers/player_provider.dart';
import '../providers/account_provider.dart';
import '../models/song.dart';
import '../services/lyrics_service.dart';
import '../widgets/marquee_text.dart';
import '../widgets/glass_container.dart';

// PlayerScreen is the full-screen playback interface of the app.
// It features an interactive vinyl turntable (which users can scratch like a DJ!),
// synchronized scrolling lyrics, a progress bar, playback controls, and real-time audio effects.
class PlayerScreen extends StatefulWidget {
  // Const constructor for the PlayerScreen.
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

// State class managing animations, interactive turntable scratching gestures,
// lyrics fetching, synchronized auto-scrolling, and audio effects controls.
class _PlayerScreenState extends State<PlayerScreen>
    with TickerProviderStateMixin {
  // MethodChannel to communicate with native Android code for sharing songs and saving files.
  static const MethodChannel _deviceFilesChannel =
      MethodChannel('musico/device_files');

  // Animation controller that continuously rotates the vinyl record when music is playing.
  late AnimationController _vinylCtrl;

  // Active view tab index: 0 = Vinyl record player view, 1 = Synchronized lyrics view.
  int _tab = 0;

  // Whether the audio effects panel (Speed, Bass, Reverb, Pitch) is currently expanded.
  bool _showEffects = false;

  // True when the user is actively touching and spinning/scratching the vinyl record.
  bool _scratching = false;

  // Stores the touch angle (in radians) from the previous frame to calculate rotation movement.
  double? _lastScratchAngle;

  // The calculated song timestamp while the user is actively scrubbing/scratching the record.
  Duration _scratchPosition = Duration.zero;

  // Timestamp of the last seek command, used to throttle seeking so we don't overwhelm the audio engine.
  DateTime _lastScratchSeekAt = DateTime.fromMillisecondsSinceEpoch(0);

  // Temporary seek value in seconds while the user is dragging the progress bar slider thumb.
  double? _pendingSeekSeconds;

  // List of parsed synchronized lyric lines for the currently playing song.
  List<LyricsLine>? _lyrics;

  // True when timed lyrics are actively being fetched from the internet.
  bool _lyricsLoading = false;

  // Song ID for which lyrics have already been successfully loaded.
  String? _lyricsLoadedFor;

  // Song ID for which lyrics are currently being fetched (prevents redundant duplicate fetches).
  String? _lyricsLoadingFor;

  // ScrollController to smoothly auto-scroll the lyrics list as the song advances.
  final ScrollController _lyricsScrollController = ScrollController();

  // Tracks the index of the currently active/highlighted lyric line.
  int _lastLyricsIndex = -1;

  // Records when the user manually scrolled the lyrics, pausing auto-scroll for a few seconds.
  DateTime _lastUserScrollAt = DateTime.fromMillisecondsSinceEpoch(0);

  // Sets up the 10-second vinyl rotation animation controller and user scroll detection.
  @override
  void initState() {
    super.initState();
    // One full 360-degree rotation takes 10 seconds
    _vinylCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    );
    // Listen to scroll activity; if user scrolls manually, pause auto-scroll temporarily
    _lyricsScrollController.addListener(() {
      if (_lyricsScrollController.position.userScrollDirection !=
          ScrollDirection.idle) {
        _lastUserScrollAt = DateTime.now();
      }
    });
  }

  // Disposes the animation controller and scroll controller to prevent memory leaks.
  @override
  void dispose() {
    _vinylCtrl.dispose();
    _lyricsScrollController.dispose();
    super.dispose();
  }

  // Synchronizes the vinyl record's rotation animation with the music playback state.
  // When playing, the vinyl spins; when paused or being scratched, the rotation stops.
  void _syncAnimations(bool playing) {
    if (playing) {
      if (_scratching) {
        // While scratching with finger, stop automated rotation
        if (_vinylCtrl.isAnimating) _vinylCtrl.stop();
      } else if (!_vinylCtrl.isAnimating) {
        // Resume continuous spinning
        _vinylCtrl.repeat();
      }
      return;
    }

    // Music paused: stop spinning
    if (!_scratching && _vinylCtrl.isAnimating) _vinylCtrl.stop();
  }

  // Calculates the polar angle (in radians) of a touch point relative to the vinyl's center (125, 125).
  double _scratchAngle(Offset localPosition) {
    const center = Offset(125, 125);
    final offset = localPosition - center;
    return atan2(offset.dy, offset.dx);
  }

  // Calculates the radial distance (in pixels) from the vinyl's center to the touch position.
  double _scratchRadius(Offset localPosition) {
    const center = Offset(125, 125);
    return (localPosition - center).distance;
  }

  // Normalizes an angle difference to stay within the [-pi, +pi] range,
  // preventing sudden jumping when crossing the boundary between -pi and +pi.
  double _normaliseAngleDelta(double delta) {
    while (delta > pi) {
      delta -= pi * 2;
    }
    while (delta < -pi) {
      delta += pi * 2;
    }
    return delta;
  }

  // Ensures that scratch seeking cannot scrub into negative time or past the song's total length.
  Duration _clampScratchPosition(Duration value, Duration duration) {
    if (value.isNegative) return Duration.zero;
    if (duration > Duration.zero && value > duration) return duration;
    return value;
  }

  // Triggered when user touches down on the vinyl to start scratching.
  // Ignores touches too close to the center label (radius < 72).
  void _startScratch(DragStartDetails details, PlayerProvider provider) {
    // Only allow scratching on the outer grooves of the record
    if (_scratchRadius(details.localPosition) < 72) return;
    setState(() {
      _scratching = true;
      _lastScratchAngle = _scratchAngle(details.localPosition);
      _scratchPosition = provider.position;
      _lastScratchSeekAt = DateTime.fromMillisecondsSinceEpoch(0);
    });
    // Stop the auto-spin animation during manual scratching
    if (_vinylCtrl.isAnimating) _vinylCtrl.stop();
    // Notify audio player to temporarily pause or enter scratch mode
    unawaited(provider.beginScratch());
  }

  // Triggered as the user drags their finger around the vinyl record.
  // Rotates the vinyl visually and scrubs song playback forward or backward.
  void _updateScratch(DragUpdateDetails details, PlayerProvider provider) {
    if (!_scratching) return;
    final angle = _scratchAngle(details.localPosition);
    final previousAngle = _lastScratchAngle;
    if (previousAngle == null) {
      _lastScratchAngle = angle;
      return;
    }

    // Determine how many radians the finger turned
    final delta = _normaliseAngleDelta(angle - previousAngle);
    _lastScratchAngle = angle;

    // Manually advance or reverse the animation controller's rotation fraction [0.0 - 1.0]
    final nextTurn = (_vinylCtrl.value + delta / (pi * 2)) % 1.0;
    _vinylCtrl.value = nextTurn < 0 ? nextTurn + 1.0 : nextTurn;

    // Convert angular movement into milliseconds of audio scrubbing (approx 2.4s per full turn)
    final movementMs = (delta * 2400).round();
    _scratchPosition = _clampScratchPosition(
      _scratchPosition + Duration(milliseconds: movementMs),
      provider.duration,
    );

    // Throttle seeks to at most once every 90ms to keep playback smooth without lag
    final now = DateTime.now();
    if (now.difference(_lastScratchSeekAt) > const Duration(milliseconds: 90)) {
      _lastScratchSeekAt = now;
      unawaited(provider.scratchTo(_scratchPosition, delta));
    }
  }

  // Triggered when user lifts their finger off the vinyl record.
  // Commits the final seek position and restores normal playback.
  void _endScratch(PlayerProvider provider) {
    if (!_scratching) return;
    unawaited(provider.endScratch(_scratchPosition));
    setState(() {
      _scratching = false;
      _lastScratchAngle = null;
    });
    _syncAnimations(provider.isPlaying);
  }

  // Fetches synchronized lyrics for the given song from online lyrics providers.
  Future<void> _loadLyrics(Song song) async {
    // Avoid re-fetching if lyrics are already loaded or currently loading for this song
    if (_lyricsLoadedFor == song.id || _lyricsLoadingFor == song.id) return;
    setState(() {
      _lyrics = null;
      _lyricsLoading = true;
      _lyricsLoadingFor = song.id;
    });
    final lines = await LyricsService.getLyricsForSong(song);
    if (mounted) {
      setState(() {
        _lyrics = lines;
        _lyricsLoadedFor = song.id;
        _lyricsLoadingFor = null;
        _lyricsLoading = false;
      });
    }
  }

  // Builds the player screen UI, reacting to changes in PlayerProvider.
  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerProvider>(
      builder: (ctx, provider, _) {
        // Keep vinyl rotation animation in sync with current playback state
        _syncAnimations(provider.isPlaying);
        final song = provider.currentSong;

        // If no song is currently playing, display a helpful empty screen
        if (song == null) {
          return Scaffold(
            backgroundColor: const Color(0xFF0A0A0F),
            body: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.music_off_outlined,
                      color: Colors.white24, size: 64),
                  const SizedBox(height: 16),
                  const Text('No song selected',
                      style: TextStyle(color: Colors.white54, fontSize: 16)),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(ctx),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFB06EF3),
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('Go Back'),
                  ),
                ],
              ),
            ),
          );
        }

        // If user is viewing the Lyrics tab, automatically trigger lyrics load for the song
        if (_tab == 1 &&
            _lyricsLoadedFor != song.id &&
            _lyricsLoadingFor != song.id) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _loadLyrics(song);
          });
        }

        return Scaffold(
          backgroundColor: Colors.transparent,
          body: Container(
            // Rich radial gradient creating atmospheric studio lighting from top-left
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.topLeft,
                radius: 1.5,
                colors: [
                  Color(0xFF16102B),
                  Color(0xFF0B0B14),
                  Color(0xFF12121A),
                ],
                stops: [0.0, 0.4, 1.0],
              ),
            ),
            child: SafeArea(
              child: Column(
                children: [
                  // Top bar with dismiss arrow, album label, download icon, share button, and favorite heart
                  _topBar(ctx, provider, song),
                  // Pill tab switcher for Vinyl vs Lyrics view
                  _tabSwitcher(),
                  // Active tab content (Vinyl turntable player or synchronized lyrics)
                  Expanded(
                    child: _tabView(provider, song),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ── Top Bar ───────────────────────────────────────────────────────────────

  // Builds the header bar containing navigation, track information, and action icons.
  Widget _topBar(BuildContext ctx, PlayerProvider provider, Song song) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          // Down arrow button to collapse the player and return to the previous screen
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down,
                color: Colors.white, size: 30),
            onPressed: () => Navigator.pop(ctx),
          ),
          // Center title column showing "NOW PLAYING" and album name
          Expanded(
            child: Column(
              children: [
                const Text('NOW PLAYING',
                    style: TextStyle(
                        color: Colors.white54,
                        fontSize: 11,
                        letterSpacing: 2.5,
                        fontWeight: FontWeight.bold)),
                Text(song.album,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.35),
                        fontSize: 11)),
              ],
            ),
          ),
          // In-app and device download management buttons
          _downloadControls(ctx, provider, song),
          // Share button to send song details or web links to other apps
          IconButton(
            tooltip: 'Share song',
            icon: const Icon(
              Icons.ios_share_rounded,
              color: Colors.white70,
              size: 22,
            ),
            onPressed: () => _shareSong(song),
          ),
          // Like / favorite heart button toggles liked status in local library & YouTube
          IconButton(
            icon: Icon(
              provider.isLiked ? Icons.favorite : Icons.favorite_border,
              color:
                  provider.isLiked ? const Color(0xFFB06EF3) : Colors.white70,
            ),
            onPressed: () => provider.toggleLike(
              account: context.read<AccountProvider>(),
            ),
          ),
        ],
      ),
    );
  }

  // Invokes native Android share sheet or copies song link to clipboard if sharing fails.
  Future<void> _shareSong(Song song) async {
    final text = _shareText(song);
    try {
      await _deviceFilesChannel.invokeMethod<bool>('shareText', {
        'text': text,
      });
    } catch (e) {
      // Fallback to copying text to clipboard
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Song details copied to clipboard'),
          backgroundColor: Color(0xFF141420),
        ),
      );
    }
  }

  // Formats the readable text snippet to share (Title, Artist, and web link).
  String _shareText(Song song) {
    final buffer = StringBuffer('${song.title} - ${song.artist}');
    final link = _shareLink(song);
    if (link != null) buffer.write('\n$link');
    return buffer.toString();
  }

  // Constructs a playable web link for YouTube or JioSaavn.
  String? _shareLink(Song song) {
    if (song.source == 'youtube' && song.id.isNotEmpty) {
      return 'https://www.youtube.com/watch?v=${song.id}';
    }
    if (song.source == 'saavn' && song.id.isNotEmpty) {
      final query = Uri.encodeComponent('${song.title} ${song.artist}');
      return 'https://www.jiosaavn.com/search/song/$query';
    }
    return null;
  }

  // Builds the download icons: in-app caching (offline playback) and exporting to device storage.
  Widget _downloadControls(
      BuildContext context, PlayerProvider provider, Song song) {
    // Show spinner if download is currently in progress
    if (provider.isDownloading(song)) {
      final progress = provider.downloadProgress(song);
      return SizedBox(
        width: 48,
        height: 48,
        child: Padding(
          padding: const EdgeInsets.all(13),
          child: CircularProgressIndicator(
            value: progress > 0 ? progress.clamp(0.0, 1.0).toDouble() : null,
            strokeWidth: 2,
            color: const Color(0xFF6EF3E9),
            backgroundColor: Colors.white10,
          ),
        ),
      );
    }

    final downloaded = provider.isDownloaded(song);
    final exporting = provider.isExportingToDevice(song);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Button 1: Download for offline listening inside the app (or remove offline copy)
        IconButton(
          tooltip: downloaded ? 'Remove offline copy' : 'Download in app',
          icon: Icon(
            downloaded ? Icons.download_done_rounded : Icons.download_rounded,
            color: downloaded ? const Color(0xFF6EF3E9) : Colors.white70,
          ),
          onPressed: () async {
            if (downloaded) {
              await provider.removeDownload(song);
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Removed offline copy'),
                  backgroundColor: Color(0xFF141420),
                ),
              );
            } else {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Downloading in app...'),
                    backgroundColor: Color(0xFF141420),
                  ),
                );
              }

              final ok = await provider.downloadSong(song);
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(ok
                      ? 'Downloaded in app'
                      : 'Download failed. Try another song/source.'),
                  backgroundColor: const Color(0xFF141420),
                ),
              );
            }
          },
        ),
        // Button 2: Export to device storage as MP3 file, with optional custom audio effects applied
        if (downloaded)
          exporting
              ? const SizedBox(
                  width: 42,
                  height: 42,
                  child: Padding(
                    padding: EdgeInsets.all(11),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFF6EF3E9),
                    ),
                  ),
                )
              : IconButton(
                  tooltip: 'Download to device',
                  icon: const Icon(
                    Icons.save_alt_rounded,
                    color: Colors.white70,
                  ),
                  onPressed: () async {
                    // Ask the user if they want the normal audio or version with current effects (e.g. Slowed + Reverb)
                    final choice = await showDialog<String>(
                      context: context,
                      builder: (context) => AlertDialog(
                        backgroundColor: const Color(0xFF1A1A2E),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        title: const Text('Download Option',
                            style: TextStyle(color: Colors.white)),
                        content: const Text(
                            'Do you want to download the normal version or apply current audio effects (Slowed, Bass, Reverb, Pitch)?',
                            style: TextStyle(color: Colors.white70)),
                        actions: [
                          TextButton(
                            child: const Text('Normal',
                                style: TextStyle(color: Colors.white60)),
                            onPressed: () => Navigator.pop(context, 'normal'),
                          ),
                          TextButton(
                            child: const Text('Applied Effects',
                                style: TextStyle(color: Color(0xFFB06EF3))),
                            onPressed: () => Navigator.pop(context, 'effects'),
                          ),
                        ],
                      ),
                    );

                    if (choice == null) return;

                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(choice == 'effects'
                              ? 'Exporting with effects...'
                              : 'Exporting normal version...'),
                          backgroundColor: const Color(0xFF141420),
                        ),
                      );
                    }

                    // Perform file export to device Downloads/Musico folder
                    final saved = await provider.downloadToDevice(
                      song,
                      applyEffects: choice == 'effects',
                    );
                    if (!context.mounted) return;
                    
                    // Show confirmation alert with the final status
                    showDialog(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        backgroundColor: const Color(0xFF141420),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
                        ),
                        title: Row(
                          children: [
                            Icon(
                              saved != null
                                  ? Icons.check_circle_outline_rounded
                                  : Icons.error_outline_rounded,
                              color: saved != null
                                  ? const Color(0xFF6EF3E9)
                                  : const Color(0xFFFF9B9B),
                              size: 28,
                            ),
                            const SizedBox(width: 10),
                            Text(
                              saved != null ? 'Download Success' : 'Download Failed',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 18,
                              ),
                            ),
                          ],
                        ),
                        content: Text(
                          saved != null
                              ? 'The song "${song.title}" was successfully saved to your device Downloads under the "Musico" folder.'
                              : 'Could not save "${song.title}" to device. Please try again.',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.72),
                            fontSize: 14,
                            height: 1.4,
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text(
                              'OK',
                              style: TextStyle(
                                color: Color(0xFFB06EF3),
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
      ],
    );
  }

  // ── Tab switcher ──────────────────────────────────────────────────────────

  // Builds the pill-shaped segmented switch bar to toggle between the vinyl player and lyrics.
  Widget _tabSwitcher() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      height: 36,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          _tabBtn(0, 'Vinyl'),
          _tabBtn(1, 'Lyrics'),
        ],
      ),
    );
  }

  // Builds an individual toggle button within the tab switcher.
  Widget _tabBtn(int idx, String label) {
    final selected = _tab == idx;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _tab = idx),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFB06EF3) : Colors.transparent,
            borderRadius: BorderRadius.circular(18),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.white : Colors.white38,
              fontWeight: FontWeight.bold,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }

  // Selects which body to show: the turntable player view or the synchronized lyrics view.
  Widget _tabView(PlayerProvider provider, Song song) {
    if (_tab == 0) return _playerView(provider, song);
    return _lyricsView(provider);
  }

  // ── Player View ───────────────────────────────────────────────────────────

  // ── Player View ───────────────────────────────────────────────────────────

  // Builds the primary player tab: shows vinyl, track info, seekbar, controls, and effects.
  Widget _playerView(PlayerProvider provider, Song song) {
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        const SizedBox(height: 8),
        // Interactive rotating & scratchable vinyl turntable
        _vinyl(provider, song),
        const SizedBox(height: 16),
        // Song title, artist, source badge, and shuffle/repeat buttons
        _songInfo(song, provider),
        const SizedBox(height: 10),
        // Playback seek bar slider with elapsed and remaining timestamps
        _progressBar(provider),
        const SizedBox(height: 6),
        // Previous, rewind 10s, Play/Pause, skip 10s, next buttons
        _controls(provider),
        // Toggle button to show or hide the audio equalizer / effects sheet
        _effectsToggle(),
        // Expandable panel for Speed, Bass boost, Reverb, and Pitch
        if (_showEffects) _effectsPanel(provider),
        const SizedBox(height: 32),
      ],
    );
  }

  // ── Lyrics View ───────────────────────────────────────────────────────────

  // Builds the synchronized lyrics screen that auto-scrolls in real-time as the song plays.
  Widget _lyricsView(PlayerProvider provider) {
    // Show spinner while fetching lyrics from the server
    if (_lyricsLoading) {
      return const Center(
          child: CircularProgressIndicator(color: Color(0xFFB06EF3)));
    }
    // Show empty state if no lyrics were found for this track
    if (_lyrics == null || _lyrics!.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.lyrics_outlined, color: Colors.white24, size: 56),
            const SizedBox(height: 16),
            const Text('No lyrics available',
                style: TextStyle(color: Colors.white54, fontSize: 16)),
            const SizedBox(height: 8),
            // Retry button
            TextButton(
              onPressed: () {
                setState(() {
                  _lyricsLoadedFor = null;
                  _lyricsLoadingFor = null;
                });
                final song = provider.currentSong;
                if (song != null) _loadLyrics(song);
              },
              child: const Text('Try again',
                  style: TextStyle(color: Color(0xFFB06EF3))),
            ),
          ],
        ),
      );
    }

    // Determine the active lyric line based on current playback timestamp
    final pos = provider.position;
    int currentIdx = 0;
    for (int i = 0; i < _lyrics!.length; i++) {
      if (_lyrics![i].timestamp <= pos) currentIdx = i;
    }

    // Automatically scroll to keep the active lyric centered, unless user recently scrolled manually
    if (currentIdx != _lastLyricsIndex) {
      _lastLyricsIndex = currentIdx;
      
      final now = DateTime.now();
      final timeSinceUserScroll = now.difference(_lastUserScrollAt);
      
      // Wait 3 seconds after user touch scroll before resuming automated following
      if (timeSinceUserScroll >= const Duration(seconds: 3)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_lyricsScrollController.hasClients) {
            _lyricsScrollController.animateTo(
              (currentIdx * 48.0) - 180.0, // Estimated item height - center offset
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeInOut,
            );
          }
        });
      }
    }

    // List of clickable lyric lines
    return ListView.builder(
      controller: _lyricsScrollController,
      padding: const EdgeInsets.fromLTRB(24, 160, 24, 280),
      itemCount: _lyrics!.length,
      itemBuilder: (ctx, i) {
        final isActive = i == currentIdx;
        final line = _lyrics![i];
        return InkWell(
          borderRadius: BorderRadius.circular(8),
          // Tapping any lyric line seeks the player directly to that exact line's timestamp!
          onTap: () => provider.seek(line.timestamp),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
            child: Text(
              line.text.isEmpty ? '-' : line.text,
              textAlign: TextAlign.center,
              style: TextStyle(
                // Active sung line is bright white and bold; upcoming/past lines are muted
                color: isActive ? Colors.white : Colors.white24,
                fontSize: isActive ? 20 : 16,
                fontWeight: isActive ? FontWeight.w900 : FontWeight.w500,
                height: 1.4,
              ),
            ),
          ),
        );
      },
    );
  }

  // ── Vinyl ─────────────────────────────────────────────────────────────────

  // Builds the interactive vinyl record with circular artwork, grooves, and turntable tone arm.
  // Supports dragging gesture to scratch audio forward and backward like a real DJ!
  Widget _vinyl(PlayerProvider provider, Song song) {
    return Center(
      child: GestureDetector(
        // Detect dragging gestures for scratching
        onPanStart: (details) => _startScratch(details, provider),
        onPanUpdate: (details) => _updateScratch(details, provider),
        onPanEnd: (_) => _endScratch(provider),
        onPanCancel: () => _endScratch(provider),
        child: RepaintBoundary(
          child: SizedBox(
            width: 250,
            height: 250,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Layer 1: Ambient purple neon glow pulsing beneath the vinyl
                AnimatedContainer(
                  duration: const Duration(milliseconds: 600),
                  width: 250,
                  height: 250,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFFB06EF3).withValues(
                            alpha: provider.isPlaying ? 0.45 : 0.12),
                        blurRadius: 34,
                        spreadRadius: 8,
                      ),
                    ],
                  ),
                ),
                // Layer 2: Rotating vinyl record disc
                RotationTransition(
                  turns: _vinylCtrl,
                  child: Container(
                    width: 230,
                    height: 230,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle, 
                      color: const Color(0xFF141414).withValues(alpha: 0.6), // Translucent dark
                      border: Border.all(color: const Color(0xFFB06EF3).withValues(alpha: 0.3), width: 1.5),
                    ),
                    child: ClipOval(
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 12.0, sigmaY: 12.0),
                        child: CustomPaint(
                          painter: _VinylPainter(), // Custom painter drawing the groove rings
                          child: Center(
                            child: Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white30, width: 2), // Added circle boundary
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(0xFFB06EF3).withValues(alpha: 0.5),
                                    blurRadius: 16,
                                    spreadRadius: 2,
                                  ),
                                ],
                              ),
                              // Circular song album cover thumbnail in center of vinyl
                              child: ClipOval(
                                child: song.thumbnailUrl.isNotEmpty
                                  ? CachedNetworkImage(
                                      imageUrl: song.thumbnailUrl,
                                      width: 120,
                                      height: 120,
                                      fit: BoxFit.cover,
                                      placeholder: (_, __) => _artDefault(120),
                                      errorWidget: (_, __, ___) => _artDefault(120),
                                    )
                                  : _artDefault(120),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // Layer 3: Center spindle hole of the turntable
                Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF0A0A0F),
                    border: Border.all(color: Colors.white12, width: 1.5),
                  ),
                ),
                // Layer 4: Turntable tonearm (stylus needle) that pivots onto the record when playing
                Positioned(
                  right: 10,
                  top: 18,
                  child: AnimatedRotation(
                    duration: const Duration(milliseconds: 600),
                    turns: _scratching
                        ? 0.12
                        : provider.isPlaying
                            ? 0.04
                            : 0.09,
                    alignment: Alignment.topCenter,
                    child: Column(
                      children: [
                        // Tonearm pivot base
                        Container(
                            width: 10,
                            height: 10,
                            decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Color(0xFFB06EF3))),
                        // Tonearm metal rod
                        Container(
                            width: 3,
                            height: 65,
                            decoration: BoxDecoration(
                                color: Colors.grey.shade500,
                                borderRadius: BorderRadius.circular(2))),
                        // Tonearm cartridge head
                        Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                                shape: BoxShape.circle, color: Colors.white30)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Placeholder art container displayed when thumbnail is loading or missing.
  Widget _artDefault(double size) => Container(
        width: size,
        height: size,
        color: const Color(0xFF1A1A2E),
        child: const Icon(Icons.music_note, color: Color(0xFFB06EF3), size: 40),
      );

  // ── Song Info ─────────────────────────────────────────────────────────────

  // ── Song Info ─────────────────────────────────────────────────────────────

  // Displays song title and artist (using auto-scrolling marquee text if names are long),
  // stream origin badge (e.g. YouTube vs JioSaavn), and shuffle / repeat mode buttons.
  Widget _songInfo(Song song, PlayerProvider provider) {
    // Current streaming status label
    final status = provider.isLoading
        ? 'Preparing audio...'
        : provider.error == PlayerError.none
            ? _sourceLabel(song.source)
            : 'Looking for a playable stream...';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Row(
        children: [
          // Title, artist, and status message column
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Scrolling marquee title (handles extra long song names gracefully)
                SizedBox(
                  height: 28,
                  child: MarqueeText(
                    text: song.title,
                    style: GoogleFonts.spaceGrotesk(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                // Scrolling marquee artist name
                SizedBox(
                  height: 20,
                  child: MarqueeText(
                    text: song.artist,
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.55),
                        fontSize: 14),
                  ),
                ),
                const SizedBox(height: 4),
                // Animated badge displaying the audio stream source or loading/error status
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: Text(
                    status,
                    key: ValueKey(status),
                    style: TextStyle(
                      color: provider.error == PlayerError.none
                          ? Colors.white.withValues(alpha: 0.34)
                          : const Color(0xFFFF8A80),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Shuffle and Repeat toggles row
          Row(
            children: [
              // Shuffle button: plays queue in random order when enabled
              IconButton(
                icon: Icon(
                  provider.shuffleOn
                      ? Icons.shuffle_on_rounded
                      : Icons.shuffle_rounded,
                  color: provider.shuffleOn
                      ? const Color(0xFFB06EF3)
                      : Colors.white38,
                  size: 22,
                ),
                onPressed: provider.toggleShuffle,
              ),
              // Repeat button: loops single track (repeat-one) or entire queue
              IconButton(
                icon: Icon(
                  provider.repeatOne
                      ? Icons.repeat_one_rounded
                      : Icons.repeat_rounded,
                  color: provider.repeatOne
                      ? const Color(0xFFB06EF3)
                      : Colors.white38,
                  size: 22,
                ),
                onPressed: provider.toggleRepeat,
              ),
            ],
          ),
        ],
      ),
    );
  }

  // Returns user-friendly text describing where the audio is currently playing from.
  String _sourceLabel(String source) {
    if (source == 'youtube') return 'Online audio';
    if (source == 'saavn') return 'Fallback audio';
    return source;
  }

  // ── Progress Bar ──────────────────────────────────────────────────────────

  // Builds the interactive playback progress seek bar with elapsed time and total length.
  Widget _progressBar(PlayerProvider provider) {
    // Use pending seek position while user is sliding the thumb, otherwise use provider's current position
    final pos = _pendingSeekSeconds ?? provider.position.inSeconds.toDouble();
    final dur = provider.duration.inSeconds.toDouble();
    final isUnknown = dur <= 0;
    
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          // Customized slider with neon purple theme styling
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: const Color(0xFFB06EF3),
              inactiveTrackColor: Colors.white.withValues(alpha: 0.08),
              thumbColor: const Color(0xFFE0C4FF),
              overlayColor: const Color(0xFFB06EF3).withValues(alpha: 0.25),
              trackHeight: 2.5,
              thumbShape: isUnknown 
                  ? SliderComponentShape.noThumb 
                  : const RoundSliderThumbShape(enabledThumbRadius: 6, elevation: 8),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              value: isUnknown ? 0 : pos.clamp(0.0, dur).toDouble(),
              min: 0,
              max: isUnknown ? 1 : dur,
              // While dragging thumb: update local UI without seeking audio yet
              onChanged: isUnknown ? null : (v) => setState(() => _pendingSeekSeconds = v),
              // On release: seek the actual audio player to the chosen position
              onChangeEnd: isUnknown ? null : (v) {
                setState(() => _pendingSeekSeconds = null);
                provider.seek(Duration(seconds: v.toInt()));
              },
            ),
          ),
          // Time labels below slider (Elapsed on left, Total duration on right)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _fmt(Duration(seconds: pos.toInt())),
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                Text(
                  isUnknown ? '--:--' : _fmt(provider.duration),
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Controls ──────────────────────────────────────────────────────────────

  // Builds the main playback control buttons: Previous, -10s rewind, Play/Pause, +10s forward, Next.
  Widget _controls(PlayerProvider provider) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Skip to previous track in playlist
          _iconBtn(Icons.skip_previous_rounded,
              size: 34, onTap: provider.playPrevious),
          // Jump backwards 10 seconds
          _iconBtn(Icons.replay_10_rounded,
              size: 28,
              onTap: () => provider
                  .seek(provider.position - const Duration(seconds: 10))),
          // Prominent central Play / Pause button with glowing gradient
          GestureDetector(
            onTap: provider.togglePlayPause,
            child: Container(
              width: 68,
              height: 68,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                    colors: [Color(0xFFB06EF3), Color(0xFF6E9EF3)]),
                boxShadow: [
                  BoxShadow(
                      color: const Color(0xFFB06EF3).withValues(alpha: 0.32),
                      blurRadius: 18,
                      spreadRadius: 0)
                ],
              ),
              child: provider.isLoading
                  ? const Padding(
                      padding: EdgeInsets.all(20),
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2.5))
                  : Icon(
                      provider.isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 36,
                    ),
            ),
          ),
          // Jump forwards 10 seconds
          _iconBtn(Icons.forward_10_rounded,
              size: 28,
              onTap: () => provider
                  .seek(provider.position + const Duration(seconds: 10))),
          // Skip to next track in playlist
          _iconBtn(Icons.skip_next_rounded, size: 34, onTap: provider.playNext),
        ],
      ),
    );
  }

  // Helper function to build a standardized circular icon button.
  Widget _iconBtn(IconData icon,
      {required double size, required VoidCallback onTap}) {
    return IconButton(
      icon: Icon(icon, color: Colors.white, size: size),
      onPressed: onTap,
    );
  }

  // ── Effects Panel ─────────────────────────────────────────────────────────

  // Builds the button that expands or collapses the audio effects control panel.
  Widget _effectsToggle() {
    return TextButton.icon(
      onPressed: () => setState(() => _showEffects = !_showEffects),
      icon: AnimatedRotation(
        turns: _showEffects ? 0.5 : 0,
        duration: const Duration(milliseconds: 300),
        child: const Icon(Icons.tune, color: Color(0xFFB06EF3), size: 20),
      ),
      label: Text(
        _showEffects ? 'Hide Effects' : 'Audio Effects',
        style: const TextStyle(
            color: Color(0xFFB06EF3), fontWeight: FontWeight.w600),
      ),
    );
  }

  // Glassmorphic floating panel for real-time sound customization (speed, bass boost, reverb, pitch).
  Widget _effectsPanel(PlayerProvider provider) {
    return GlassContainer(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      opacity: 0.04,
      blur: 16.0,
      borderRadius: BorderRadius.circular(8),
      border:
          Border.all(color: const Color(0xFFB06EF3).withValues(alpha: 0.25)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Audio Effects',
            style: GoogleFonts.spaceGrotesk(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 12),
          // Playback speed slider (0.5x slowed to 2.0x nightcore/sped-up)
          _slider(
            label: 'Speed',
            value: provider.speed,
            min: 0.5,
            max: 2.0,
            display: '${provider.speed.toStringAsFixed(2)}x',
            color: const Color(0xFF6E9EF3),
            onChanged: (v) {
              provider.setSpeed(v);
            },
          ),
          // Bass boost equalizer slider
          _slider(
            label: 'Bass Boost',
            value: provider.bass,
            min: 0.0,
            max: 1.0,
            display: '${(provider.bass * 100).toInt()}%',
            color: const Color(0xFFF38A6E),
            onChanged: provider.setBass,
          ),
          // Reverb ambience slider
          _slider(
            label: 'Reverb',
            value: provider.reverb,
            min: 0.0,
            max: 1.0,
            display: '${(provider.reverb * 100).toInt()}%',
            color: const Color(0xFF8CE99A),
            onChanged: provider.setReverb,
          ),
          // Toggle switch for independent pitch adjustment
          _effectSwitch(
            label: 'Pitch Control',
            value: provider.pitchEnabled,
            onChanged: provider.setPitchEnabled,
          ),
          // Pitch slider (only active when Pitch Control switch is turned on)
          _slider(
            label: provider.pitchEnabled ? 'Pitch' : 'Pitch follows speed',
            value: provider.pitchEnabled ? provider.pitch : provider.speed,
            min: 0.5,
            max: 2.0,
            display: provider.pitchEnabled
                ? '${provider.pitch.toStringAsFixed(2)}x'
                : '${provider.speed.toStringAsFixed(2)}x',
            color: const Color(0xFF6EF3E9),
            onChanged: provider.pitchEnabled ? provider.setPitch : null,
          ),
          // Reset button to revert all audio effects back to neutral defaults
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () {
                provider.setSpeed(1.0);
                provider.setBass(0.0);
                provider.setReverb(0.0);
                provider.setPitchEnabled(false);
              },
              child: const Text('Reset All',
                  style: TextStyle(color: Colors.white38, fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }

  // Helper widget to render an effect toggle switch row.
  Widget _effectSwitch({
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Switch.adaptive(
            value: value,
            activeThumbColor: const Color(0xFF6EF3E9),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  // Reusable slider control with title, color-coded value badge, and slider track.
  Widget _slider({
    required String label,
    required double value,
    required double min,
    required double max,
    required String display,
    required Color color,
    required ValueChanged<double>? onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label,
                  style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: color.withValues(alpha: 0.4)),
                ),
                child: Text(display,
                    style: TextStyle(
                        color: color,
                        fontSize: 12,
                        fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: color,
              inactiveTrackColor: Colors.white10,
              thumbColor: color,
              overlayColor: color.withValues(alpha: 0.15),
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            ),
            child:
                Slider(value: value, min: min, max: max, onChanged: onChanged),
          ),
        ],
      ),
    );
  }

  // Formats a Duration object into a readable time string (e.g. "3:45" or "1:02:30").
  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (h > 0) return '$h:$m:$s';
    return '${d.inMinutes}:$s';
  }
}

// ── Vinyl CustomPainter ───────────────────────────────────────────────────────

// Custom painter that draws the authentic grooves, light reflections, and center label of a vinyl record.
class _VinylPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    // 1. Outer subtle gradient sweep reflection (mimics light hitting shiny vinyl plastic)
    final reflectPaint = Paint()
      ..style = PaintingStyle.fill
      ..shader = const SweepGradient(
        colors: [
          Colors.white12,
          Colors.transparent,
          Colors.white12,
          Colors.transparent,
          Colors.white12,
        ],
        stops: [0.0, 0.25, 0.5, 0.75, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, reflectPaint);

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;

    // 2. Draw 35 concentric micro-grooves across the record surface
    for (int i = 0; i < 35; i++) {
      final r = 60.0 + i * 2.5;
      if (r > radius - 5) break;
      paint.color = Colors.white.withValues(alpha: 0.02 + (i % 3) * 0.015);
      canvas.drawCircle(center, r, paint);
    }

    // 3. Inner record label disc with deep purple radial gradient
    final labelPaint = Paint()
      ..style = PaintingStyle.fill
      ..shader = const RadialGradient(
        colors: [
          Color(0xFF381460),
          Color(0xFF1A1440),
          Color(0xFF0F0F1A),
        ],
        stops: [0.0, 0.6, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: 55));
    canvas.drawCircle(center, 55, labelPaint);

    // 4. Neon glow aura surrounding the inner label
    final glowPaint = Paint()
      ..color = const Color(0xFFB06EF3).withValues(alpha: 0.4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10.0
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12.0);
    canvas.drawCircle(center, 58, glowPaint);

    // 5. Crisp inner ring border
    paint
      ..color = const Color(0xFFB06EF3).withValues(alpha: 0.8)
      ..strokeWidth = 2.0;
    canvas.drawCircle(center, 55, paint);
  }

  // Geometry of the record grooves does not change dynamically, so return false to save CPU/GPU cycles.
  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

