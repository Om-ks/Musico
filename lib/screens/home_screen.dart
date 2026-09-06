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
import '../widgets/add_to_playlist_sheet.dart';
import 'playlist_detail_screen.dart';

// HomeScreen is the main landing screen of the app.
// It displays personalized music recommendations, trending songs, albums, and category filter chips.
class HomeScreen extends StatefulWidget {
  // Callback function triggered when the user taps the top-left menu icon (opens side drawer/menu).
  final VoidCallback? onOpenMenu;

  // Constructor allowing an optional onOpenMenu callback.
  const HomeScreen({super.key, this.onOpenMenu});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

// State class for HomeScreen that manages feed data loading, category chip selection, and UI rendering.
class _HomeScreenState extends State<HomeScreen> {
  // Helper service for reading and writing local data (such as user listening history).
  final _storage = StorageService();

  // Holds the recommended music feed data (chips, sections of songs/playlists) received from the server.
  HomeFeedData? _feedData;

  // Counter to track the latest fetch request and ignore responses from older, obsolete requests.
  int _fetchId = 0;

  // Indicates whether music data is currently being fetched from the network.
  bool _loading = true;

  // Tracks the previous sign-in authentication state to detect when the user logs in or out.
  String? _lastAuthState;

  // Stores the text of the currently selected filter chip (e.g., "Relax", "Workout"), or null if none selected.
  String? _selectedChipText;

  // Called when this widget is first inserted into the widget tree.
  @override
  void initState() {
    super.initState();
    // No need to fetch here, _onAuthChanged will handle the initial fetch
  }

  // Called whenever the user's login/authorization status changes.
  // It resets any selected filter chip and re-fetches the feed suited for the new auth state.
  void _onAuthChanged(String newState) {
    if (_lastAuthState != newState) {
      _lastAuthState = newState;
      _selectedChipText = null;
      // Fetch fresh home feed data for the new account state
      _fetchFeed(firstLoad: true);
    }
  }

  // Fetches the home feed data from either YouTube Music (if logged in) or the local recommendation service.
  // [firstLoad] displays a full-screen loading spinner when true.
  // [token] is an optional continuation token used when filtering by a specific category chip.
  Future<void> _fetchFeed({bool firstLoad = false, String? token}) async {
    // Increment fetch counter to mark this as the most recent request
    _fetchId++;
    final currentId = _fetchId;
    // Show spinner if this is a fresh reload and the widget is still active on screen
    if (mounted && firstLoad) setState(() => _loading = true);

    try {
      final account = context.read<AccountProvider>();
      // If the user is logged into YouTube, fetch their personalized YouTube Music feed;
      // otherwise, fetch general recommendations based on locally stored listening history.
      final data = account.youtubeAuthorized 
          ? await account.fetchHomeFeed(continuationToken: token)
          : await ApiService.getRecommendedSections(await _storage.getListeningHistory());
          
      // Discard this response if a newer fetch request was triggered while this was awaiting
      if (_fetchId != currentId) return;
      if (mounted) setState(() => _feedData = data);
    } catch (_) {
      // Silently swallow errors so existing feed sections remain visible without crashing
    } finally {
      // Only turn off loading state if this is still the most recent request
      if (_fetchId == currentId && mounted) setState(() => _loading = false);
    }
  }

  // Handles user taps on a category filter chip (e.g. "Energize", "Relax").
  // If the tapped chip is already selected, it deselects it and restores the default feed.
  // Otherwise, it selects the chip and loads filtered music using the chip's continuation token.
  void _onChipTapped(HomeFeedChip chip) {
    if (_selectedChipText == chip.text) {
      // User tapped the already selected chip -> deselect it and load default feed
      setState(() {
        _selectedChipText = null;
      });
      _fetchFeed(firstLoad: true, token: null);
    } else {
      // User tapped a different chip -> select it and fetch music tailored to this category
      setState(() {
        _selectedChipText = chip.text;
      });
      _fetchFeed(firstLoad: true, token: chip.token);
    }
  }

  // Builds the visual UI tree for the home screen.
  @override
  Widget build(BuildContext context) {
    // Watch AccountProvider to re-render if user sign-in status changes
    final account = context.watch<AccountProvider>();

    // Trigger feed refresh when sign-in state changes (without setState loop)
    final authState = '${account.isSignedIn}_${account.youtubeAuthorized}';
    SchedulerBinding.instance.addPostFrameCallback((_) => _onAuthChanged(authState));

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: CustomScrollView(
        slivers: [
          // Sticky top app bar with logo, menu button, and refresh action
          _buildSliverAppBar(),

          // Show animated loading pulse when fetching music for the first time
          if (_loading)
            const SliverFillRemaining(
              child: Center(child: LoadingPulse()),
            )
          else ...[
            // Horizontal list of filter chips (categories like Relax, Workout, etc.)
            if (_feedData != null && _feedData!.chips.isNotEmpty)
              SliverToBoxAdapter(
                child: _buildChips(_feedData!.chips),
              ),

            // Dynamic sections of content (e.g., Quick picks, Albums, Trending)
            if (_feedData != null)
              for (final section in _feedData!.sections) ...[
                if (section.items.isNotEmpty) ...[
                  // Section header title
                  SliverToBoxAdapter(
                    child: _buildSectionLabel(section.title),
                  ),
                  // Content grid or carousel for this section
                  SliverToBoxAdapter(
                    child: _buildDynamicSection(section),
                  ),
                ],
              ],

            // Bottom padding to ensure content is not hidden behind the floating mini-player
            const SliverToBoxAdapter(child: SizedBox(height: 160)),
          ],
        ],
      ),
    );
  }

  // Builds the pinned sliver app bar with the Musico logo and top action buttons.
  Widget _buildSliverAppBar() {
    return SliverAppBar(
      pinned: true, // Keeps the app bar visible at the top while scrolling
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
        // Button to open the navigation drawer / side menu
        IconButton(
          icon: const Icon(Icons.menu_rounded, color: Colors.white70),
          onPressed: widget.onOpenMenu,
        ),
        // Button to manually refresh the home feed
        IconButton(
          icon: const Icon(Icons.refresh, color: Colors.white70),
          onPressed: _fetchFeed,
        ),
      ],
    );
  }

  // Formats and builds the category section title with consistent font styling and padding.
  Widget _buildSectionLabel(String text) {
    // Clean up or standardize common section titles for better readability
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

  // Builds the horizontal scrollable row of category pill chips (e.g., Workout, Focus, Relax).
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
                  // Highlight the selected chip with white background, dark grey for unselected
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

  // Dynamically selects the best visual layout (square cards, dense grid, or carousel)
  // based on the section's title and the types of items it contains.
  Widget _buildDynamicSection(MusicRecommendationSection section) {
    final title = section.title.toLowerCase();
    
    // 1. Explicitly large square cards (for playlists, albums, new releases, and artist recommendations)
    if (title.contains('similar to') || title.contains('fresh finds') || title.contains('albums') || title.contains('new releases') || title.contains('discover')) {
      return _buildPlaylistCards(section.items);
    }
    // 2. Square Grids with 2 rows (often used by YouTube Music for "Speed Dial" and "Mixed for you")
    else if (title.contains('speed dial') || title.contains('mixed for you')) {
      return _buildSquareGridCards(section.items);
    } 
    // 3. Dense List Grids with 4 rows for quick song picking (e.g., "Quick picks", "Trending", "Listen again")
    else if (title.contains('quick picks') || title.contains('trending') || title.contains('remixes') || title.contains('listen again')) {
      return _buildGridCards(section.items, rows: 4);
    }
    
    // 4. Default fallbacks: if all items are songs, show compact grid; otherwise show playlist cards
    if (section.songs.length == section.items.length && section.items.isNotEmpty) {
      return _buildGridCards(section.items, rows: 4);
    }
    return _buildPlaylistCards(section.items);
  }

  // Builds a 2-row horizontally scrolling grid of medium-sized square cards (for "Speed Dial").
  // Tapping a song plays it immediately; tapping a playlist navigates to its details screen.
  Widget _buildSquareGridCards(List<dynamic> items) {
    return SizedBox(
      height: 240, // Height accommodates 2 rows of items (~110px each + spacing)
      child: GridView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2, // 2 rows of cards
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.1, // Aspect ratio slightly taller than wide to fit text below art
        ),
        itemCount: items.length,
        itemBuilder: (ctx, i) {
          final item = items[i];
          String title = '';
          String subtitle = '';
          String thumb = '';

          // Extract title, subtitle, and thumbnail based on whether the item is a Song or Playlist
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
            // Long pressing a song opens the "Add to Playlist" bottom sheet
            onLongPress: () {
              if (item is Song) {
                showAddToPlaylistSheet(context, item);
              }
            },
            // Tapping plays the song or opens the playlist details page
            onTap: () {
              if (item is Song) {
                // Collect all songs in this section to form an active queue/playlist
                final allSongs = items.whereType<Song>().toList();
                context.read<PlayerProvider>().playSong(item, playlist: allSongs.isNotEmpty ? allSongs : [item]);
              } else if (item is MusicPlaylist) {
                Navigator.push(context, MaterialPageRoute(builder: (_) => RemotePlaylistScreen(playlist: item)));
              }
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Item thumbnail image with rounded corners
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
                // Title text (single line, elided if too long)
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                ),
                // Subtitle (artist or playlist owner)
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

  // Builds a multi-row horizontal grid of songs with small thumbnail and text rows
  // (commonly used for "Quick Picks", matching the YouTube Music 4-row layout).
  Widget _buildGridCards(List<dynamic> items, {int rows = 4}) {
    final double itemHeight = 60.0;
    return SizedBox(
      height: rows * itemHeight, // Height sized to fit the specified number of rows
      child: GridView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: rows,
          mainAxisSpacing: 12,
          crossAxisSpacing: 8,
          childAspectRatio: 60 / 300, // Fixed width-to-height ratio for each song item row
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
            // Long press on a song opens the option to add it to a playlist
            onLongPress: () {
              if (item is Song) {
                showAddToPlaylistSheet(context, item);
              }
            },
            // Tapping plays the song and queues the sibling songs in this section
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
                // Song thumbnail image
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
                // Song title and artist text column
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


  // Builds a horizontally scrolling carousel of larger rectangular cards for playlists and albums.
  Widget _buildPlaylistCards(List<dynamic> items) {
    return SizedBox(
      height: 178,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: items.length,
        itemBuilder: (ctx, i) {
          final item = items[i];
          String title = '';
          String owner = '';
          String thumb = '';

          // Determine card display details depending on item type
          if (item is Song) {
            title = item.title;
            owner = item.artist;
            thumb = item.thumbnailUrl;
          } else if (item is MusicPlaylist) {
            title = item.title;
            owner = item.owner;
            thumb = item.thumbnailUrl;
          }

          return GestureDetector(
            // Tapping navigates to the playlist detail screen to view all songs in it
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => RemotePlaylistScreen(
                  playlist: item is MusicPlaylist
                      ? item
                      : const MusicPlaylist(
                          id: '',
                          title: '',
                          owner: '',
                          thumbnailUrl: '',
                          itemCount: 0,
                          source: 'youtube',
                        ),
                ),
              ),
            ),
            child: Container(
              width: 148,
              margin: const EdgeInsets.symmetric(horizontal: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Playlist or album cover art with cached image loading
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
                  // Playlist title
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
                  // Playlist curator / owner
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

  // Fallback placeholder container shown when a song has no artwork or while loading.
  Widget _defaultArt() {
    return Container(
      color: const Color(0xFF1A1A2E),
      child: const Center(
        child: Icon(Icons.music_note, color: Color(0xFFB06EF3), size: 36),
      ),
    );
  }

  // Fallback placeholder container shown when a playlist has no cover art or while loading.
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

// LoadingPulse is an animated placeholder displayed in the center of the screen
// while the initial music recommendations feed is being fetched.
class LoadingPulse extends StatefulWidget {
  const LoadingPulse({super.key});

  @override
  State<LoadingPulse> createState() => _LoadingPulseState();
}

// State class managing the pulse animation controller for the loading indicator.
class _LoadingPulseState extends State<LoadingPulse>
    with SingleTickerProviderStateMixin {
  // Animation controller that pulses repeatedly back and forth
  late AnimationController _c;

  @override
  void initState() {
    super.initState();
    // 900ms repeat cycle with reverse creates a smooth breathing/pulsing effect
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    // Always dispose animation controllers when the widget is removed to avoid memory leaks
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
          // App icon logo with slight padding
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
          // Subtle loading message
          Text('Loading music...',
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5), fontSize: 15)),
        ],
      ),
    );
  }
}
