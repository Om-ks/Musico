// Data models needed to structure the user's music library.
import 'music_playlist.dart';
import 'song.dart';

// Represents the user's complete music collection in the app.
// 
// This model bundles together the user's liked tracks, listening history
// (recent songs), and all custom or synced playlists into a single immutable snapshot.
// It serves as the primary data structure displayed on the Library screen.
class AccountLibrary {
  // The collection of tracks the user has liked (favorited).
  final List<Song> likedSongs;

  // The collection of tracks the user has recently listened to.
  final List<Song> recentSongs;

  // The list of playlists created by the user or synced from their account.
  final List<MusicPlaylist> playlists;

  // Default constructor allowing optional initialization of lists, defaulting to empty lists.
  const AccountLibrary({
    this.likedSongs = const [],
    this.recentSongs = const [],
    this.playlists = const [],
  });

  // A singleton-style constant representing an uninitialized or empty user library.
  // Useful as a safe initial state before account data is loaded or after logout.
  static const empty = AccountLibrary();
}
