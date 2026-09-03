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
  int _fetchId = 0;
  bool _loading = true;
  String? _lastAuthState;
  String? _selectedChipText;

  @override
  void initState() {
    super.initState();
    // No need to fetch here, _onAuthChanged will handle the initial fetch
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
    _fetchId++;
    final currentId = _fetchId;
    if (mounted && firstLoad) setState(() => _loading = true);

    try {
      final account = context.read<AccountProvider>();
      final data = account.youtubeAuthorized 
          ? await account.fetchHomeFeed(continuationToken: token)
          : await ApiService.getRecommendedSections(await _storage.getListeningHistory());
          
      if (_fetchId != currentId) return; // A newer fetch started
      if (mounted) setState(() => _feedData = data);
    } catch (_) {
      // Silently swallow — library sections stay visible
    } finally {
      if (_fetchId == currentId && mounted) setState(() => _loading = false);
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
                  if (section.items.isNotEmpty) ...[
                    SliverToBoxAdapter(
                      child: _buildSectionLabel(section.title),
                    ),
                    SliverToBoxAdapter(
                      child: _buildDynamicSection(section),
                    ),
                  ],
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
      height: 48,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        itemCount: chips.length,
        itemBuilder: (ctx, i) {
          final chip = chips[i];
          final isSelected = _selectedChipText == chip.text;
          
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: () => _onChipTapped(chip),
              child: Container(
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: isSelected ? Colors.white : const Color(0xFF212121), // YT Music dark grey chip
                  borderRadius: BorderRadius.circular(18), // Pill shape
                  border: Border.all(color: isSelected ? Colors.transparent : Colors.white24, width: 0.5),
                ),
                child: Text(
                  chip.text,
                  style: TextStyle(
                    color: isSelected ? Colors.black : Colors.white,
                    fontSize: 15,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildDynamicSection(MusicRecommendationSection section) {
    final title = section.title.toLowerCase();
    
    // 1. Explicitly large square cards
    if (title.contains('similar to') || title.contains('fresh finds') || title.contains('albums') || title.contains('new releases') || title.contains('discover')) {
      return _buildPlaylistCards(section.items);
    }
    // 2. Square Grids (Speed Dial)
    else if (title.contains('speed dial') || title.contains('mixed for you')) {
      return _buildSquareGridCards(section.items);
    } 
    // 3. Dense List Grids (Songs)
    else if (title.contains('quick picks') || title.contains('trending') || title.contains('remixes') || title.contains('listen again')) {
      return _buildGridCards(section.items, rows: 4);
    }
    
    // 4. Default fallbacks
    if (section.songs.length == section.items.length && section.items.isNotEmpty) {
      return _buildGridCards(section.items, rows: 4);
    }
    return _buildPlaylistCards(section.items);
  }

  Widget _buildSquareGridCards(List<dynamic> items) {
    return SizedBox(
      height: 240, // 2 rows of ~110
      child: GridView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2, // 2 rows
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.1, // slightly taller than wide to fit text
        ),
        itemCount: items.length,
        itemBuilder: (ctx, i) {
          final item = items[i];
          String title = '';
          String subtitle = '';
          String thumb = '';
          if (item is Song) {
            title = item.title;
            subtitle = item.artist;
            thumb = item.thumbnailUrl;
          } else if (item is MusicPlaylist) {
            title = item.title;
            subtitle = item.owner;
            thumb = item.thumbnailUrl;
          }
          return GestureDetector(
            onTap: () {
              if (item is Song) {
                final allSongs = items.whereType<Song>().toList();
                context.read<PlayerProvider>().playSong(item, playlist: allSongs.isNotEmpty ? allSongs : [item]);
              } else if (item is MusicPlaylist) {
                Navigator.push(context, MaterialPageRoute(builder: (_) => RemotePlaylistScreen(playlist: item)));
              }
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: thumb.isNotEmpty
                        ? CachedNetworkImage(
                            imageUrl: thumb,
                            width: double.infinity,
                            fit: BoxFit.cover,
                            placeholder: (_, __) => _playlistDefaultArt(),
                            errorWidget: (_, __, ___) => _playlistDefaultArt(),
                          )
                        : _playlistDefaultArt(),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                ),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 11),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildGridCards(List<dynamic> items, {int rows = 4}) {
    final double itemHeight = 60.0;
    return SizedBox(
      height: rows * itemHeight,
      child: GridView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: rows,
          mainAxisSpacing: 12,
          crossAxisSpacing: 8,
          childAspectRatio: 60 / 300,
        ),
        itemCount: items.length,
        itemBuilder: (ctx, i) {
          final item = items[i];
          
          String title = '';
          String subtitle = '';
          String thumb = '';
          
          if (item is Song) {
            title = item.title;
            subtitle = item.artist;
            thumb = item.thumbnailUrl;
          } else if (item is MusicPlaylist) {
            title = item.title;
            subtitle = item.owner;
            thumb = item.thumbnailUrl;
          }
          
          return GestureDetector(
            onTap: () {
              if (item is Song) {
                final allSongs = items.whereType<Song>().toList();
                context.read<PlayerProvider>().playSong(item, playlist: allSongs);
              } else if (item is MusicPlaylist) {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => RemotePlaylistScreen(playlist: item),
                  ),
                );
              }
            },
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: thumb.isNotEmpty 
                      ? CachedNetworkImage(
                          imageUrl: thumb,
                          width: 48,
                          height: 48,
                          fit: BoxFit.cover,
                          placeholder: (_, __) => Container(color: const Color(0xFF1A1A2E)),
                          errorWidget: (_, __, ___) => _defaultArt(),
                        )
                      : _defaultArt(),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        title,
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
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.6),
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


Widget _buildPlaylistCards(List<dynamic> items) {
    return SizedBox(
      height: 178,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: items.length,
        itemBuilder: (ctx, i) {
            final item = items[i];
          String title = ''; String owner = ''; String thumb = '';
          if (item is Song) { title = item.title; owner = item.artist; thumb = item.thumbnailUrl; } 
          else if (item is MusicPlaylist) { title = item.title; owner = item.owner; thumb = item.thumbnailUrl; }
          return GestureDetector(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => RemotePlaylistScreen(playlist: item is MusicPlaylist ? item : const MusicPlaylist(id: '', title: '', owner: '', thumbnailUrl: '', itemCount: 0, source: 'youtube')),
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
                    child: thumb.isNotEmpty
                        ? CachedNetworkImage(
                            imageUrl: thumb,
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
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    owner,
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
