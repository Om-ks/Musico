import 'music_playlist.dart';
import 'song.dart';

class AccountLibrary {
  final List<Song> likedSongs;
  final List<Song> recentSongs;
  final List<MusicPlaylist> playlists;

  const AccountLibrary({
    this.likedSongs = const [],
    this.recentSongs = const [],
    this.playlists = const [],
  });

  static const empty = AccountLibrary();
}
