import 'dart:io';

void main() {
  final file = File('lib/screens/home_screen.dart');
  var content = file.readAsStringSync();
  
  // Update state variables
  content = content.replaceFirst('List<Song> _trending = [];\n  List<MusicRecommendationSection> _recommended = [];', 'HomeFeedData? _feedData;');
  
  // Update _fetchFeed
  final oldFetch = '''  Future<void> _fetchFeed() async {
    setState(() {
      _loading = true;
      _error = false;
    });

    try {
      final account = context.read<AccountProvider>();
      final isYoutubeAuthorized = account.youtubeAuthorized;
      
      final futures = <Future>[];
      
      if (isYoutubeAuthorized) {
        // Fetch official YouTube Music home feed if logged in
        futures.add(account.fetchHomeFeed().then((sections) {
          if (mounted) setState(() => _recommended = sections);
        }));
      } else {
        // Fallback to local recommendations if logged out
        final history = await _storage.getListeningHistory();
        futures.add(ApiService.getRecommendedSections(history).then((sections) {
          if (mounted) setState(() => _recommended = sections);
        }));
      }
      
      // Also fetch trending as a fallback/additional section
      futures.add(ApiService.getTrending().then((list) {
        if (mounted) {
          setState(() {
            _trending = list;
          });
        }
      }));
      
      await Future.wait(futures);
    } catch (e) {
      if (mounted) setState(() => _error = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }''';
  
  final newFetch = '''  Future<void> _fetchFeed() async {
    setState(() {
      _loading = true;
      _error = false;
    });

    try {
      final account = context.read<AccountProvider>();
      final isYoutubeAuthorized = account.youtubeAuthorized;
      
      final futures = <Future>[];
      
      if (isYoutubeAuthorized) {
        futures.add(account.fetchHomeFeed().then((data) {
          if (mounted) setState(() => _feedData = data);
        }));
      } else {
        final history = await _storage.getListeningHistory();
        futures.add(ApiService.getRecommendedSections(history).then((data) {
          if (mounted) setState(() => _feedData = data);
        }));
      }
      
      await Future.wait(futures);
    } catch (e) {
      if (mounted) setState(() => _error = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }''';
  
  content = content.replaceFirst(oldFetch, newFetch);
  
  // Replace build and _buildFeaturedBanner
  final oldBuildToBannerEnd = RegExp(r'  @override\s+Widget build\(BuildContext context\) \{.*?\Widget _buildFeaturedBanner\(Song\? song\) \{.*?\}\n', dotAll: true);
  
  final newBuild = '''  @override
  Widget build(BuildContext context) {
    final account = context.watch<AccountProvider>();
    final ytLib = account.library;
    final signedIn = account.isSignedIn;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      body: CustomScrollView(
        slivers: [
          _buildSliverAppBar(),
          if (_loading)
            const SliverFillRemaining(
              child: Center(child: LoadingPulse()),
            )
          else if (_error)
            SliverFillRemaining(
              child: _ErrorView(onRetry: _fetchFeed),
            )
          else ...[
            if (_feedData != null && _feedData!.chips.isNotEmpty)
              SliverToBoxAdapter(
                child: _buildChips(_feedData!.chips),
              ),

            // YouTube Library Sections
            if (signedIn && account.youtubeAuthorized) ...[
              if (ytLib.likedSongs.isNotEmpty) ...[
                SliverToBoxAdapter(
                  child: _buildSectionLabel('Your Liked Music'),
                ),
                SliverToBoxAdapter(
                  child: _buildHorizontalCards(ytLib.likedSongs),
                ),
              ],
              if (ytLib.playlists.isNotEmpty) ...[
                SliverToBoxAdapter(
                  child: _buildSectionLabel('Your Playlists'),
                ),
                SliverToBoxAdapter(
                  child: _buildPlaylistCards(ytLib.playlists.take(10).toList()),
                ),
              ],
              if (ytLib.recentSongs.isNotEmpty) ...[
                SliverToBoxAdapter(
                  child: _buildSectionLabel('Recently Played (YouTube)'),
                ),
                SliverToBoxAdapter(
                  child: _buildHorizontalCards(
                    ytLib.recentSongs.take(10).toList(),
                    isRecents: true,
                  ),
                ),
              ],
            ],

            if (_feedData != null)
              for (final section in _feedData!.sections) ...[
                SliverToBoxAdapter(
                  child: _buildSectionLabel(section.title),
                ),
                if (section.playlists.isNotEmpty && section.songs.isEmpty)
                  SliverToBoxAdapter(
                    child: _buildPlaylistCards(section.playlists),
                  )
                else if (section.songs.isNotEmpty)
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
''';

  content = content.replaceFirst(oldBuildToBannerEnd, newBuild);
  
  file.writeAsStringSync(content);
}
