import 'package:flutter/material.dart';

// Custom bottom navigation bar widget providing top-level navigation between
// Home, Search, and Library screens with rounded top corners.
class BottomNav extends StatelessWidget {
  // The currently active tab index (0 = Home, 1 = Search, 2 = Library).
  final int currentIndex;

  // Callback triggered when the user taps on any tab item, receiving the new index.
  final ValueChanged<int> onTap;

  // Constructor requiring the active tab index and tab tap callback.
  const BottomNav({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Clip the top corners to achieve a modern curved sheet appearance.
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1A1A24), // Solid dark background color matching app theme.
        ),
        child: BottomNavigationBar(
          currentIndex: currentIndex,
          onTap: onTap,
          type: BottomNavigationBarType.fixed,
          backgroundColor: Colors.transparent,
          elevation: 0,
          selectedItemColor: const Color(0xFFB06EF3), // Accent purple for the active tab.
          unselectedItemColor: Colors.white38, // Muted grey for inactive tabs.
          selectedLabelStyle:
              const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
          unselectedLabelStyle: const TextStyle(fontSize: 11),
          items: const [
            // Tab 0: Home screen feed.
            BottomNavigationBarItem(
              icon: Icon(Icons.home_rounded),
              label: 'Home',
            ),
            // Tab 1: Search screen for discovering music and playlists.
            BottomNavigationBarItem(
              icon: Icon(Icons.search_rounded),
              label: 'Search',
            ),
            // Tab 2: User library (playlists, downloads, history, liked tracks).
            BottomNavigationBarItem(
              icon: Icon(Icons.library_music_rounded),
              label: 'Library',
            ),
          ],
        ),
      ),
    );
  }
}

