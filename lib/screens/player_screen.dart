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

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with TickerProviderStateMixin {
  static const MethodChannel _deviceFilesChannel =
      MethodChannel('musico/device_files');

  late AnimationController _vinylCtrl;

  // Tabs: 0 = player, 1 = lyrics
  int _tab = 0;

  bool _showEffects = false;
  bool _scratching = false;
  double? _lastScratchAngle;
  Duration _scratchPosition = Duration.zero;
  DateTime _lastScratchSeekAt = DateTime.fromMillisecondsSinceEpoch(0);
  double? _pendingSeekSeconds;

  List<LyricsLine>? _lyrics;
  bool _lyricsLoading = false;
  String? _lyricsLoadedFor;
  String? _lyricsLoadingFor;
  final ScrollController _lyricsScrollController = ScrollController();
  int _lastLyricsIndex = -1;
  DateTime _lastUserScrollAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _vinylCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    );
    _lyricsScrollController.addListener(() {
      if (_lyricsScrollController.position.userScrollDirection !=
          ScrollDirection.idle) {
        _lastUserScrollAt = DateTime.now();
      }
    });
  }

  @override
  void dispose() {
    _vinylCtrl.dispose();
    _lyricsScrollController.dispose();
    super.dispose();
  }

  void _syncAnimations(bool playing) {
    if (playing) {
      if (_scratching) {
        if (_vinylCtrl.isAnimating) _vinylCtrl.stop();
      } else if (!_vinylCtrl.isAnimating) {
        _vinylCtrl.repeat();
      }
      return;
    }

    if (!_scratching && _vinylCtrl.isAnimating) _vinylCtrl.stop();
  }

  double _scratchAngle(Offset localPosition) {
    const center = Offset(125, 125);
    final offset = localPosition - center;
    return atan2(offset.dy, offset.dx);
  }

  double _scratchRadius(Offset localPosition) {
    const center = Offset(125, 125);
    return (localPosition - center).distance;
  }

  double _normaliseAngleDelta(double delta) {
    while (delta > pi) {
      delta -= pi * 2;
    }
    while (delta < -pi) {
      delta += pi * 2;
    }
    return delta;
  }

  Duration _clampScratchPosition(Duration value, Duration duration) {
    if (value.isNegative) return Duration.zero;
    if (duration > Duration.zero && value > duration) return duration;
    return value;
  }

  void _startScratch(DragStartDetails details, PlayerProvider provider) {
    if (_scratchRadius(details.localPosition) < 72) return;
    setState(() {
      _scratching = true;
      _lastScratchAngle = _scratchAngle(details.localPosition);
      _scratchPosition = provider.position;
      _lastScratchSeekAt = DateTime.fromMillisecondsSinceEpoch(0);
    });
    if (_vinylCtrl.isAnimating) _vinylCtrl.stop();
    unawaited(provider.beginScratch());
  }

  void _updateScratch(DragUpdateDetails details, PlayerProvider provider) {
    if (!_scratching) return;
    final angle = _scratchAngle(details.localPosition);
    final previousAngle = _lastScratchAngle;
    if (previousAngle == null) {
      _lastScratchAngle = angle;
      return;
    }

    final delta = _normaliseAngleDelta(angle - previousAngle);
    _lastScratchAngle = angle;

    final nextTurn = (_vinylCtrl.value + delta / (pi * 2)) % 1.0;
    _vinylCtrl.value = nextTurn < 0 ? nextTurn + 1.0 : nextTurn;

    final movementMs = (delta * 2400).round();
    _scratchPosition = _clampScratchPosition(
      _scratchPosition + Duration(milliseconds: movementMs),
      provider.duration,
    );

    final now = DateTime.now();
    if (now.difference(_lastScratchSeekAt) > const Duration(milliseconds: 90)) {
      _lastScratchSeekAt = now;
      unawaited(provider.scratchTo(_scratchPosition, delta));
    }
  }

  void _endScratch(PlayerProvider provider) {
    if (!_scratching) return;
    unawaited(provider.endScratch(_scratchPosition));
    setState(() {
      _scratching = false;
      _lastScratchAngle = null;
    });
    _syncAnimations(provider.isPlaying);
  }

  Future<void> _loadLyrics(Song song) async {
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

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerProvider>(
      builder: (ctx, provider, _) {
        _syncAnimations(provider.isPlaying);
        final song = provider.currentSong;

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
                  _topBar(ctx, provider, song),
                  _tabSwitcher(),
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

  Widget _topBar(BuildContext ctx, PlayerProvider provider, Song song) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down,
                color: Colors.white, size: 30),
            onPressed: () => Navigator.pop(ctx),
          ),
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
          _downloadControls(ctx, provider, song),
          IconButton(
            tooltip: 'Share song',
            icon: const Icon(
              Icons.ios_share_rounded,
              color: Colors.white70,
              size: 22,
            ),
            onPressed: () => _shareSong(song),
          ),
          IconButton(
            icon: Consumer<AccountProvider>(
              builder: (ctx, account, _) {
                final isLiked = account.isLoggedIn ? account.isSongLiked(song.id) : provider.isLiked;
                return Icon(
                  isLiked ? Icons.favorite : Icons.favorite_border,
                  color: isLiked ? const Color(0xFFB06EF3) : Colors.white70,
                );
              },
            ),
            onPressed: () {
              provider.toggleLike(account: context.read<AccountProvider>());
            },
          ),
        ],
      ),
    );
  }

  Future<void> _shareSong(Song song) async {
    final text = _shareText(song);
    try {
      await _deviceFilesChannel.invokeMethod<bool>('shareText', {
        'text': text,
      });
    } catch (e) {
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

  String _shareText(Song song) {
    final buffer = StringBuffer('${song.title} - ${song.artist}');
    final link = _shareLink(song);
    if (link != null) buffer.write('\n$link');
    return buffer.toString();
  }

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

  Widget _downloadControls(
      BuildContext context, PlayerProvider provider, Song song) {
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

                    final saved = await provider.downloadToDevice(
                      song,
                      applyEffects: choice == 'effects',
                    );
                    if (!context.mounted) return;
                    
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

  Widget _tabView(PlayerProvider provider, Song song) {
    if (_tab == 0) return _playerView(provider, song);
    return _lyricsView(provider);
  }

  // ── Player View ───────────────────────────────────────────────────────────

  Widget _playerView(PlayerProvider provider, Song song) {
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        const SizedBox(height: 8),
        _vinyl(provider, song),
        const SizedBox(height: 16),
        _songInfo(song, provider),
        const SizedBox(height: 10),
        _progressBar(provider),
        const SizedBox(height: 6),
        _controls(provider),
        _effectsToggle(),
        if (_showEffects) _effectsPanel(provider),
        const SizedBox(height: 32),
      ],
    );
  }

  // ── Lyrics View ───────────────────────────────────────────────────────────

  Widget _lyricsView(PlayerProvider provider) {
    if (_lyricsLoading) {
      return const Center(
          child: CircularProgressIndicator(color: Color(0xFFB06EF3)));
    }
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

    final pos = provider.position;
    int currentIdx = 0;
    for (int i = 0; i < _lyrics!.length; i++) {
      if (_lyrics![i].timestamp <= pos) currentIdx = i;
    }

    if (currentIdx != _lastLyricsIndex) {
      _lastLyricsIndex = currentIdx;
      
      final now = DateTime.now();
      final timeSinceUserScroll = now.difference(_lastUserScrollAt);
      
      if (timeSinceUserScroll >= const Duration(seconds: 3)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_lyricsScrollController.hasClients) {
            _lyricsScrollController.animateTo(
              (currentIdx * 48.0) - 180.0, // Estimated item height - offset
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeInOut,
            );
          }
        });
      }
    }

    return ListView.builder(
      controller: _lyricsScrollController,
      padding: const EdgeInsets.fromLTRB(24, 160, 24, 280),
      itemCount: _lyrics!.length,
      itemBuilder: (ctx, i) {
        final isActive = i == currentIdx;
        final line = _lyrics![i];
        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => provider.seek(line.timestamp),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
            child: Text(
              line.text.isEmpty ? '-' : line.text,
              textAlign: TextAlign.center,
              style: TextStyle(
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

  Widget _vinyl(PlayerProvider provider, Song song) {
    return Center(
      child: GestureDetector(
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
                          painter: _VinylPainter(),
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
                Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF0A0A0F),
                    border: Border.all(color: Colors.white12, width: 1.5),
                  ),
                ),
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
                        Container(
                            width: 10,
                            height: 10,
                            decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Color(0xFFB06EF3))),
                        Container(
                            width: 3,
                            height: 65,
                            decoration: BoxDecoration(
                                color: Colors.grey.shade500,
                                borderRadius: BorderRadius.circular(2))),
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

  Widget _artDefault(double size) => Container(
        width: size,
        height: size,
        color: const Color(0xFF1A1A2E),
        child: const Icon(Icons.music_note, color: Color(0xFFB06EF3), size: 40),
      );

  // ── Song Info ─────────────────────────────────────────────────────────────

  Widget _songInfo(Song song, PlayerProvider provider) {
    final status = provider.isLoading
        ? 'Preparing audio...'
        : provider.error == PlayerError.none
            ? _sourceLabel(song.source)
            : 'Looking for a playable stream...';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
          Row(
            children: [
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

  String _sourceLabel(String source) {
    if (source == 'youtube') return 'Online audio';
    if (source == 'saavn') return 'Fallback audio';
    return source;
  }

  // ── Progress Bar ──────────────────────────────────────────────────────────

  Widget _progressBar(PlayerProvider provider) {
    final pos = _pendingSeekSeconds ?? provider.position.inSeconds.toDouble();
    final dur = provider.duration.inSeconds.toDouble();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: const Color(0xFFB06EF3),
              inactiveTrackColor: Colors.white.withValues(alpha: 0.08),
              thumbColor: const Color(0xFFE0C4FF),
              overlayColor: const Color(0xFFB06EF3).withValues(alpha: 0.25),
              trackHeight: 2.5,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6, elevation: 8),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              value: dur > 0 ? pos.clamp(0.0, dur).toDouble() : 0,
              min: 0,
              max: dur > 0 ? dur : 1,
              onChanged: (v) => setState(() => _pendingSeekSeconds = v),
              onChangeEnd: (v) {
                setState(() => _pendingSeekSeconds = null);
                provider.seek(Duration(seconds: v.toInt()));
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_fmt(Duration(seconds: pos.toInt())),
                    style:
                        const TextStyle(color: Colors.white54, fontSize: 12)),
                Text(_fmt(provider.duration),
                    style:
                        const TextStyle(color: Colors.white54, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Controls ──────────────────────────────────────────────────────────────

  Widget _controls(PlayerProvider provider) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _iconBtn(Icons.skip_previous_rounded,
              size: 34, onTap: provider.playPrevious),
          _iconBtn(Icons.replay_10_rounded,
              size: 28,
              onTap: () => provider
                  .seek(provider.position - const Duration(seconds: 10))),
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
          _iconBtn(Icons.forward_10_rounded,
              size: 28,
              onTap: () => provider
                  .seek(provider.position + const Duration(seconds: 10))),
          _iconBtn(Icons.skip_next_rounded, size: 34, onTap: provider.playNext),
        ],
      ),
    );
  }

  Widget _iconBtn(IconData icon,
      {required double size, required VoidCallback onTap}) {
    return IconButton(
      icon: Icon(icon, color: Colors.white, size: size),
      onPressed: onTap,
    );
  }

  // ── Effects Panel ─────────────────────────────────────────────────────────

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
          _slider(
            label: 'Bass Boost',
            value: provider.bass,
            min: 0.0,
            max: 1.0,
            display: '${(provider.bass * 100).toInt()}%',
            color: const Color(0xFFF38A6E),
            onChanged: provider.setBass,
          ),
          _slider(
            label: 'Reverb',
            value: provider.reverb,
            min: 0.0,
            max: 1.0,
            display: '${(provider.reverb * 100).toInt()}%',
            color: const Color(0xFF8CE99A),
            onChanged: provider.setReverb,
          ),
          _effectSwitch(
            label: 'Pitch Control',
            value: provider.pitchEnabled,
            onChanged: provider.setPitchEnabled,
          ),
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

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

// ── Vinyl CustomPainter ───────────────────────────────────────────────────────

class _VinylPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    // Outer subtle gradient reflection
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

    // Draw record grooves
    for (int i = 0; i < 35; i++) {
      final r = 60.0 + i * 2.5;
      if (r > radius - 5) break;
      paint.color = Colors.white.withValues(alpha: 0.02 + (i % 3) * 0.015);
      canvas.drawCircle(center, r, paint);
    }

    // Inner label area
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

    // Neon glow around the inner label
    final glowPaint = Paint()
      ..color = const Color(0xFFB06EF3).withValues(alpha: 0.4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10.0
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12.0);
    canvas.drawCircle(center, 58, glowPaint);

    // Inner ring border
    paint
      ..color = const Color(0xFFB06EF3).withValues(alpha: 0.8)
      ..strokeWidth = 2.0;
    canvas.drawCircle(center, 55, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

