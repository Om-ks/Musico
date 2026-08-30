import 'dart:io';

void main() {
  final file = File('lib/screens/home_screen.dart');
  var lines = file.readAsLinesSync();
  
  final buildStart = lines.indexWhere((l) => l.contains('Widget build(BuildContext context) {'));
  final sectionLabelStart = lines.indexWhere((l) => l.contains('Widget _buildSectionLabel(String text) {'));
  
  if (buildStart != -1 && sectionLabelStart != -1) {
    lines.removeRange(buildStart, sectionLabelStart);
    
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
    
    lines.insert(buildStart, newBuild);
  }
  
  file.writeAsStringSync(lines.join('\n'));
}
