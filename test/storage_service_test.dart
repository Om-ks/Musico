import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yt_music_clone/models/song.dart';
import 'package:yt_music_clone/services/storage_service.dart';

void main() {
  const oldSong = Song(
    id: 'legacy-song',
    title: 'Legacy Track',
    artist: 'Saved Artist',
    album: 'Saved Album',
    thumbnailUrl: 'https://example.com/art.jpg',
    duration: 180,
    source: 'youtube',
  );

  test('recently played reads and migrates the old recent library key',
      () async {
    SharedPreferences.setMockInitialValues({
      'recently_played': [jsonEncode(oldSong.toJson())],
    });

    final service = StorageService();
    final recent = await service.getRecentlyPlayed();

    expect(recent, hasLength(1));
    expect(recent.single.id, oldSong.id);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('user_recent_tracks'), isNotEmpty);
    expect(prefs.getStringList('recently_played'), isNotEmpty);
  });

  test('recent searches are deduped with newest first', () async {
    SharedPreferences.setMockInitialValues({});

    final service = StorageService();
    await service.addRecentSearch('lofi beats');
    await service.addRecentSearch('night drive');
    await service.addRecentSearch('LOFI BEATS');

    expect(await service.getRecentSearches(), [
      'LOFI BEATS',
      'night drive',
    ]);
  });
}
