import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/music_playlist.dart';
import '../models/song.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';
import '../providers/player_provider.dart';
import '../providers/account_provider.dart';
import 'playlist_detail_screen.dart';

class HomeScreen extends StatefulWidget {
  final VoidCallback? onOpenMenu;

  const HomeScreen({super.key, this.onOpenMenu});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _storage = StorageService();
  HomeFeedData? _feedData;
  // Only true on the very first load so we show the spinner once.
  // On pull-to-refresh we keep existing content visible.
  bool _loading = true;
  bool _isFetching = false;
  String? _lastAuthState;
  String? _selectedChipText;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addPostFrameCallback((_) => _fetchFeed(firstLoad: true));
  }

  /// Called once after sign-in state changes (NOT on every library update).
  /// We listen in build() with a one-shot comparison so we don't create loops.
  void _onAuthChanged(String newState) {
    if (_lastAuthState != newState) {
      _lastAuthState = newState;
      _selectedChipText = null;
      _fetchFeed(firstLoad: true);
    }
  }

  Future<void> _fetchFeed({bool firstLoad = false, String? token}) async {
    if (_isFetching) return; // prevent overlapping calls
    _isFetching = true;
    if (mounted && firstLoad) setState(() => _loading = true);

    try {
      final account = context.read<AccountProvider>();
      if (account.youtubeAuthorized) {
        final data = await account.fetchHomeFeed(continuationToken: token);
        if (mounted) setState(() => _feedData = data);
      } else {
        final history = await _storage.getListeningHistory();
        final data = await ApiService.getRecommendedSections(history);
        if (mounted) setState(() => _feedData = data);
      }
    } catch (_) {
      // Silently swallow — library sections stay visible
    } finally {
      _isFetching = false;
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onChipTapped(HomeFeedChip chip) {
    if (_selectedChipText == chip.text) {
      // Deselect chip
      setState(() {
        _selectedChipText = null;
      });
      _fetchFeed(firstLoad: true, token: null);
    } else {
      // Select chip
      setState(() {
        _selectedChipText = chip.text;
      });
      _fetchFeed(firstLoad: true, token: chip.token);
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = context.watch<AccountProvider>();
    // Trigger feed refresh when sign-in state changes (without setState loop)
    final authState = '${account.isSignedIn}_${account.youtubeAuthorized}';
    SchedulerBinding.instance.addPostFrameCallback((_) => _onAuthChanged(authState));

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: CustomScrollView(
        slivers: [
          _buildSliverAppBar(),
          if (_loading)
            const SliverFillRemaining(
              child: Center(child: LoadingPulse()),
            )
          else ...[
            if (_feedData != null && _feedData!.chips.isNotEmpty)
              SliverToBoxAdapter(
                child: _buildChips(_feedData!.chips),
              ),

            if (_feedData != null)
              for (final section in _feedData!.sections) ...[
                SliverToBoxAdapter(
                  child: _buildSectionLabel(section.title),
                ),
                // Show playlist cards (albums, mixes, radios) — always preferred
                if (section.playlists.isNotEmpty)
                  SliverToBoxAdapter(
                    child: _buildPlaylistCards(section.playlists),
                  ),
                // Show song rows only when there are no playlist cards (e.g. Quick Picks)
                if (section.songs.isNotEmpty && section.playlists.isEmpty)
                  SliverToBoxAdapter(
                    child: section.songs.length > 8
                        ? _buildGridCards(section.songs)
                        : _buildHorizontalCards(section.songs),
                  ),
              ],

            const SliverToBoxAdapter(child: SizedBox(height: 160)),
          ],
        ],
      ),
    );
  }

  Widget _buildSliverAppBar() {
    return SliverAppBar(
      pinned: true,
      backgroundColor: const Color(0xFF0A0A0F),
      expandedHeight: 0,
      titleSpacing: 16,
      title: SizedBox(
        width: 118,
        height: 30,
        child: Image.asset(
          'assets/app_logo.png',
          fit: BoxFit.contain,
          alignment: Alignment.centerLeft,
        ),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.menu_rounded, color: Colors.white70),
          onPressed: widget.onOpenMenu,
        ),
        IconButton(
          icon: const Icon(Icons.refresh, color: Colors.white70),
          onPressed: _fetchFeed,
        ),
      ],
    );
  }

  Widget _buildSectionLabel(String text) {
    final label = text.contains('Trending')
        ? 'Trending Now'
        : text.contains('Global')
            ? 'Global Hot 100'
            : text;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 19,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

    Widget _buildChips(List<HomeFeedChip> chips) {
    return SizedBox(
      height: 56,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        itemCount: chips.length,
        itemBuilder: (ctx, i) {
          final chip = chips[i];
          final isSelected = _selectedChipText == chip.text;
          
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: () => _onChipTapped(chip),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: isSelected ? Colors.white : const Color(0xFF1A1A2E),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: isSelected ? Colors.transparent : Colors.white12),
                ),
                child: Center(
                  child: Text(
                    chip.text,
                    style: TextStyle(
                      color: isSelected ? Colors.black : Colors.white,
                      fontSize: 14,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildGridCards(List<Song> songs) {
    return SizedBox(
      height: 240, // 4 rows of 60
      child: GridView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,
          mainAxisSpacing: 12,
          crossAxisSpacing: 8,
          childAspectRatio: 60 / 300, // height / width roughly
        ),
        itemCount: songs.length,
        itemBuilder: (ctx, i) {
          final song = songs[i];
          return GestureDetector(
            onTap: () => context.read<PlayerProvider>().playSong(song, playlist: songs),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: CachedNetworkImage(
                    imageUrl: song.thumbnailUrl,
                    width: 48,
                    height: 48,
                    fit: BoxFit.cover,
                    placeholder: (_, __) => Container(color: const Color(0xFF1A1A2E)),
                    errorWidget: (_, __, ___) => _defaultArt(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        song.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.6),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildHorizontalCards(List<Song> songs, {bool isRecents = false}) {
    return SizedBox(
      height: 210,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: songs.length,
        itemBuilder: (ctx, i) {
          final song = songs[i];
          return GestureDetector(
            onTap: () =>
                context.read<PlayerProvider>().playSong(song, playlist: songs),
            onLongPress: isRecents
                ? () => _showRemoveFromRecentsDialog(context, song)
                : null,
            child: Container(
              width: 148,
              margin: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: const Color(0xFF141420),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(8)),
                    child: Stack(
                      children: [
                        song.thumbnailUrl.isNotEmpty
                            ? CachedNetworkImage(
                                imageUrl: song.thumbnailUrl,
                                width: 148,
                                height: 140,
                                fit: BoxFit.cover,
                                placeholder: (_, __) => Container(
                                    height: 140, color: const Color(0xFF1A1A2E)),
                                errorWidget: (_, __, ___) =>
                                    SizedBox(height: 140, child: _defaultArt()),
                              )
                            : SizedBox(height: 140, child: _defaultArt()),
                        if (isRecents)
                          Positioned(
                            top: 4,
                            right: 4,
                            child: GestureDetector(
                              onTap: () => _showRemoveFromRecentsDialog(context, song),
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Icon(Icons.close_rounded,
                                    color: Colors.white, size: 16),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
                    child: Text(song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 2, 8, 0),
                    child: Text(song.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.5),
                            fontSize: 11)),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showRemoveFromRecentsDialog(BuildContext context, Song song) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('Remove from Recents?', style: TextStyle(color: Colors.white)),
        content: Text('Do you want to remove "${song.title}" from your recently played list?',
            style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
          ),
          TextButton(
            onPressed: () {
              context.read<PlayerProvider>().removeFromRecentlyPlayed(song);
              Navigator.pop(ctx);
              _fetchFeed(); // Refresh
            },
            child: const Text('Remove', style: TextStyle(color: Color(0xFFB06EF3))),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaylistCards(List<MusicPlaylist> playlists) {
    return SizedBox(
      height: 178,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: playlists.length,
        itemBuilder: (ctx, i) {
          final playlist = playlists[i];
          return GestureDetector(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => RemotePlaylistScreen(playlist: playlist),
              ),
            ),
            child: Container(
              width: 148,
              margin: const EdgeInsets.symmetric(horizontal: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: playlist.thumbnailUrl.isNotEmpty
                        ? CachedNetworkImage(
                            imageUrl: playlist.thumbnailUrl,
                            width: 148,
                            height: 118,
                            fit: BoxFit.cover,
                            placeholder: (_, __) => _playlistDefaultArt(),
                            errorWidget: (_, __, ___) => _playlistDefaultArt(),
                          )
                        : _playlistDefaultArt(),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    playlist.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    playlist.owner,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _defaultArt() {
    return Container(
      color: const Color(0xFF1A1A2E),
      child: const Center(
        child: Icon(Icons.music_note, color: Color(0xFFB06EF3), size: 36),
      ),
    );
  }

  Widget _playlistDefaultArt() {
    return Container(
      width: 148,
      height: 118,
      color: const Color(0xFF1A1A2E),
      child: const Center(
        child: Icon(Icons.queue_music, color: Color(0xFFB06EF3), size: 36),
      ),
    );
  }
}

class LoadingPulse extends StatefulWidget {
  const LoadingPulse({super.key});
  @override
  State<LoadingPulse> createState() => _LoadingPulseState();
}

class _LoadingPulseState extends State<LoadingPulse>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Image.asset(
              'assets/app_icon.png', // Logo 2 (Text below)
              width: 90,
              height: 90,
              fit: BoxFit.contain,
            ),
          ),
          const SizedBox(height: 16),
          Text('Loading music...',
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5), fontSize: 15)),
        ],
      ),
    );
  }
}
