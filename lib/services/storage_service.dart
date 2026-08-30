import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';

class StorageService {
  static const String _favoritesKey = 'user_favorites_tracks';
  static const String _recentKey = 'user_recent_tracks';
  static const String _historyKey = 'user_listening_history_tracks';
  static const String _recentSearchesKey = 'user_recent_searches';
  static const String _playlistsKey = 'user_custom_playlists';
  static const String _downloadsKey = 'user_downloaded_tracks';
  static const String _legacyFavoritesKey = 'liked_songs';
  static const String _legacyRecentKey = 'recently_played';
  static const String _legacyPlaylistsKey = 'playlists';

  Future<bool> isLiked(String songId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final songs = _decodeSongLists([
        prefs.getStringList(_favoritesKey) ?? const [],
        prefs.getStringList(_legacyFavoritesKey) ?? const [],
      ]);
      return songs.any((song) => song.id == songId);
    } catch (e) {
      debugPrint('Storage isLiked error: $e');
      return false;
    }
  }

  Future<void> toggleLike(Song song) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final songs = _decodeSongLists([
        prefs.getStringList(_favoritesKey) ?? const [],
        prefs.getStringList(_legacyFavoritesKey) ?? const [],
      ]);

      final existingIndex = songs.indexWhere((item) => item.id == song.id);
      if (existingIndex >= 0) {
        songs.removeAt(existingIndex);
      } else {
        songs.insert(0, song);
      }

      await _saveSongList(
        prefs,
        const [_favoritesKey, _legacyFavoritesKey],
        songs,
      );
    } catch (e) {
      debugPrint('Storage toggleLike error: $e');
    }
  }

  Future<List<Song>> getLikedSongs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final songs = _decodeSongLists([
        prefs.getStringList(_favoritesKey) ?? const [],
        prefs.getStringList(_legacyFavoritesKey) ?? const [],
      ]);
      if (songs.isNotEmpty) {
        await _saveSongList(
          prefs,
          const [_favoritesKey, _legacyFavoritesKey],
          songs,
        );
      }
      return songs;
    } catch (e) {
      debugPrint('Storage getLikedSongs error: $e');
      return [];
    }
  }

  Future<void> saveLikedSongs(List<Song> songs) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await _saveSongList(
        prefs,
        const [_favoritesKey, _legacyFavoritesKey],
        _dedupeSongs(songs),
      );
    } catch (e) {
      debugPrint('Storage saveLikedSongs error: $e');
    }
  }

  Future<void> addRecentlyPlayed(Song song) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final songs = _decodeSongLists([
        prefs.getStringList(_recentKey) ?? const [],
        prefs.getStringList(_legacyRecentKey) ?? const [],
      ]);

      songs.removeWhere((item) => _songKey(item) == _songKey(song));
      songs.insert(0, song);
      final capped = songs.length > 80 ? songs.sublist(0, 80) : songs;

      await _saveSongList(
        prefs,
        const [_recentKey, _legacyRecentKey],
        capped,
      );
      await _saveListeningHistory(prefs, song);
    } catch (e) {
      debugPrint('Storage addRecentlyPlayed error: $e');
    }
  }

  Future<void> removeRecentlyPlayed(Song song) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final songs = _decodeSongLists([
        prefs.getStringList(_recentKey) ?? const [],
        prefs.getStringList(_legacyRecentKey) ?? const [],
      ]);

      songs.removeWhere((item) => _songKey(item) == _songKey(song));

      await _saveSongList(
        prefs,
        const [_recentKey, _legacyRecentKey],
        songs,
      );
    } catch (e) {
      debugPrint('Storage removeRecentlyPlayed error: $e');
    }
  }

  Future<List<Song>> getRecentlyPlayed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final songs = _decodeSongLists([
        prefs.getStringList(_recentKey) ?? const [],
        prefs.getStringList(_legacyRecentKey) ?? const [],
      ]);
      if (songs.isNotEmpty) {
        await _saveSongList(
          prefs,
          const [_recentKey, _legacyRecentKey],
          songs,
        );
      }
      return songs;
    } catch (e) {
      debugPrint('Storage getRecentlyPlayed error: $e');
      return [];
    }
  }

  Future<void> saveRecentlyPlayed(List<Song> songs) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final capped = _dedupeSongs(songs).take(80).toList(growable: false);
      await _saveSongList(
        prefs,
        const [_recentKey, _legacyRecentKey],
        capped,
      );
    } catch (e) {
      debugPrint('Storage saveRecentlyPlayed error: $e');
    }
  }

  Future<void> mergeRecentlyPlayed(List<Song> songs) async {
    if (songs.isEmpty) return;
    final existing = await getRecentlyPlayed();
    await saveRecentlyPlayed([...songs, ...existing]);
  }

  Future<List<Song>> getListeningHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final entries =
          _decodeHistoryEntries(prefs.getStringList(_historyKey) ?? []);

      if (entries.isEmpty) return getRecentlyPlayed();

      entries.sort((a, b) {
        final scoreB = b.recommendationScore;
        final scoreA = a.recommendationScore;
        final scoreCompare = scoreB.compareTo(scoreA);
        if (scoreCompare != 0) return scoreCompare;
        return b.lastPlayed.compareTo(a.lastPlayed);
      });

      final weighted = <Song>[];
      for (final entry in entries.take(160)) {
        final repeats = entry.playCount.clamp(1, 4).toInt();
        for (var i = 0; i < repeats; i++) {
          weighted.add(entry.song);
        }
      }
      return weighted;
    } catch (e) {
      debugPrint('Storage getListeningHistory error: $e');
      return getRecentlyPlayed();
    }
  }

  Future<List<String>> getRecentSearches() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs
              .getStringList(_recentSearchesKey)
              ?.map((query) => query.trim())
              .where((query) => query.isNotEmpty)
              .toList(growable: false) ??
          const [];
    } catch (e) {
      debugPrint('Storage getRecentSearches error: $e');
      return [];
    }
  }

  Future<void> addRecentSearch(String query) async {
    try {
      final cleanQuery = query.trim();
      if (cleanQuery.isEmpty) return;

      final prefs = await SharedPreferences.getInstance();
      final searches = List<String>.from(
        prefs.getStringList(_recentSearchesKey) ?? const [],
      );
      searches.removeWhere(
        (item) => item.toLowerCase() == cleanQuery.toLowerCase(),
      );
      searches.insert(0, cleanQuery);
      await prefs.setStringList(
        _recentSearchesKey,
        searches.take(15).toList(growable: false),
      );
    } catch (e) {
      debugPrint('Storage addRecentSearch error: $e');
    }
  }

  Future<void> clearRecentSearches() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_recentSearchesKey);
    } catch (e) {
      debugPrint('Storage clearRecentSearches error: $e');
    }
  }

  Future<void> removeRecentSearch(String query) async {
    try {
      final cleanQuery = query.trim().toLowerCase();
      final prefs = await SharedPreferences.getInstance();
      final searches = List<String>.from(
        prefs.getStringList(_recentSearchesKey) ?? const [],
      );
      
      searches.removeWhere((item) => item.toLowerCase() == cleanQuery);
      
      await prefs.setStringList(_recentSearchesKey, searches);
    } catch (e) {
      debugPrint('Storage removeRecentSearch error: $e');
    }
  }

  Future<Map<String, List<Song>>> getPlaylists() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final playlists = _mergePlaylistMaps([
        _decodePlaylistMap(prefs.getString(_playlistsKey)),
        _decodePlaylistMap(prefs.getString(_legacyPlaylistsKey)),
      ]);

      if (playlists.isNotEmpty) await _savePlaylistMap(prefs, playlists);
      return playlists;
    } catch (e) {
      debugPrint('Storage getPlaylists error: $e');
      return {};
    }
  }

  Future<List<Song>> getDownloadedSongs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return _decodeDownloadEntries(prefs.getStringList(_downloadsKey) ?? [])
          .map((entry) => entry.song)
          .toList();
    } catch (e) {
      debugPrint('Storage getDownloadedSongs error: $e');
      return [];
    }
  }

  Future<Map<String, String>> getDownloadPaths() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final entries = _decodeDownloadEntries(
        prefs.getStringList(_downloadsKey) ?? [],
      );
      return {
        for (final entry in entries) _songKey(entry.song): entry.path,
      };
    } catch (e) {
      debugPrint('Storage getDownloadPaths error: $e');
      return {};
    }
  }

  Future<String?> getDownloadPath(Song song) async {
    final paths = await getDownloadPaths();
    return paths[_songKey(song)];
  }

  Future<bool> isDownloaded(Song song) async {
    final path = await getDownloadPath(song);
    return path != null && await File(path).exists();
  }

  Future<void> saveDownloadedSong(Song song, String localPath) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final entries = _decodeDownloadEntries(
        prefs.getStringList(_downloadsKey) ?? [],
      )..removeWhere((entry) => _songKey(entry.song) == _songKey(song));

      entries.insert(
        0,
        _DownloadEntry(
          song: song,
          path: localPath,
          savedAt: DateTime.now(),
        ),
      );

      await prefs.setStringList(_downloadsKey, _encodeDownloadEntries(entries));
    } catch (e) {
      debugPrint('Storage saveDownloadedSong error: $e');
    }
  }

  Future<void> removeDownloadedSong(Song song) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final entries = _decodeDownloadEntries(
        prefs.getStringList(_downloadsKey) ?? [],
      );
      final removed = <_DownloadEntry>[];

      entries.removeWhere((entry) {
        final matches = _songKey(entry.song) == _songKey(song);
        if (matches) removed.add(entry);
        return matches;
      });

      await prefs.setStringList(_downloadsKey, _encodeDownloadEntries(entries));

      for (final entry in removed) {
        try {
          final file = File(entry.path);
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('Storage removeDownloadedSong error: $e');
    }
  }

  Future<void> createPlaylist(String name) async {
    try {
      final cleanName = name.trim();
      if (cleanName.isEmpty) return;

      final prefs = await SharedPreferences.getInstance();
      final playlists = await getPlaylists();

      if (!playlists.containsKey(cleanName)) {
        playlists[cleanName] = [];
        await _savePlaylistMap(prefs, playlists);
      }
    } catch (e) {
      debugPrint('Storage createPlaylist error: $e');
    }
  }

  Future<void> deletePlaylist(String name) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final playlists = await getPlaylists();

      if (playlists.remove(name) != null) {
        await _savePlaylistMap(prefs, playlists);
      }
    } catch (e) {
      debugPrint('Storage deletePlaylist error: $e');
    }
  }

  Future<void> renamePlaylist(String oldName, String newName) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final playlists = await getPlaylists();

      if (playlists.containsKey(oldName) && newName.trim().isNotEmpty) {
        final songs = playlists.remove(oldName);
        if (songs != null) {
          playlists[newName.trim()] = songs;
          await _savePlaylistMap(prefs, playlists);
        }
      }
    } catch (e) {
      debugPrint('Storage renamePlaylist error: $e');
    }
  }

  Future<void> addSongToPlaylist(String name, Song song) async {
    try {
      final cleanName = name.trim();
      if (cleanName.isEmpty || song.id.isEmpty) return;

      final prefs = await SharedPreferences.getInstance();
      final playlists = await getPlaylists();
      final songs = playlists.putIfAbsent(cleanName, () => <Song>[]);

      songs.removeWhere((item) => _songKey(item) == _songKey(song));
      songs.insert(0, song);
      await _savePlaylistMap(prefs, playlists);
    } catch (e) {
      debugPrint('Storage addSongToPlaylist error: $e');
    }
  }

  Future<void> savePlaylist(String name, List<Song> songs) async {
    try {
      final cleanName = name.trim();
      if (cleanName.isEmpty) return;

      final prefs = await SharedPreferences.getInstance();
      final playlists = await getPlaylists();
      playlists[cleanName] = _dedupeSongs(songs);
      await _savePlaylistMap(prefs, playlists);
    } catch (e) {
      debugPrint('Storage savePlaylist error: $e');
    }
  }

  Future<void> mergePlaylist(String name, List<Song> songs) async {
    if (songs.isEmpty) return;
    final playlists = await getPlaylists();
    final existing = playlists[name.trim()] ?? const <Song>[];
    await savePlaylist(name, [...songs, ...existing]);
  }

  Future<void> removeSongFromPlaylist(String name, Song song) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final playlists = await getPlaylists();
      final songs = playlists[name];
      if (songs == null) return;

      songs.removeWhere((item) => _songKey(item) == _songKey(song));
      await _savePlaylistMap(prefs, playlists);
    } catch (e) {
      debugPrint('Storage removeSongFromPlaylist error: $e');
    }
  }

  Future<void> _savePlaylistMap(
    SharedPreferences prefs,
    Map<String, List<Song>> playlists,
  ) async {
    final jsonMap = <String, dynamic>{};
    playlists.forEach((name, songs) {
      jsonMap[name] = songs.map((song) => song.toJson()).toList();
    });
    final encoded = jsonEncode(jsonMap);
    await prefs.setString(_playlistsKey, encoded);
    await prefs.setString(_legacyPlaylistsKey, encoded);
  }

  Future<void> _saveListeningHistory(
    SharedPreferences prefs,
    Song song,
  ) async {
    final entries =
        _decodeHistoryEntries(prefs.getStringList(_historyKey) ?? []);
    final key = _songKey(song);
    final index = entries.indexWhere((entry) => _songKey(entry.song) == key);
    final now = DateTime.now();

    if (index >= 0) {
      final existing = entries[index];
      entries[index] = existing.copyWith(
        song: song,
        playCount: existing.playCount + 1,
        lastPlayed: now,
      );
    } else {
      entries.add(
        _HistoryEntry(
          song: song,
          playCount: 1,
          firstPlayed: now,
          lastPlayed: now,
        ),
      );
    }

    entries.sort((a, b) {
      final countCompare = b.playCount.compareTo(a.playCount);
      if (countCompare != 0) return countCompare;
      return b.lastPlayed.compareTo(a.lastPlayed);
    });

    final capped = entries.length > 300 ? entries.sublist(0, 300) : entries;
    await prefs.setStringList(_historyKey, _encodeHistoryEntries(capped));
  }

  List<Song> _decodeSongList(List<String> encodedSongs) {
    final songs = <Song>[];
    for (final encoded in encodedSongs) {
      try {
        final decoded = jsonDecode(encoded);
        if (decoded is Map<String, dynamic>) {
          final song = Song.fromJson(decoded);
          if (song.id.isNotEmpty) songs.add(song);
        }
      } catch (_) {}
    }
    return songs;
  }

  List<Song> _decodeSongLists(List<List<String>> encodedLists) {
    final songs = <Song>[];
    for (final encoded in encodedLists) {
      songs.addAll(_decodeSongList(encoded));
    }
    return _dedupeSongs(songs);
  }

  List<Song> _dedupeSongs(List<Song> songs) {
    final seen = <String>{};
    final deduped = <Song>[];
    for (final song in songs) {
      final key = _songKey(song);
      if (seen.add(key)) deduped.add(song);
    }
    return deduped;
  }

  Future<void> _saveSongList(
    SharedPreferences prefs,
    List<String> keys,
    List<Song> songs,
  ) async {
    final encoded = _encodeSongList(songs);
    for (final key in keys) {
      await prefs.setStringList(key, encoded);
    }
  }

  List<String> _encodeSongList(List<Song> songs) {
    return songs.map((song) => jsonEncode(song.toJson())).toList();
  }

  Map<String, List<Song>> _decodePlaylistMap(String? encodedPlaylists) {
    if (encodedPlaylists == null || encodedPlaylists.isEmpty) return {};
    try {
      final decodedMap = jsonDecode(encodedPlaylists);
      if (decodedMap is! Map<String, dynamic>) return {};

      final playlists = <String, List<Song>>{};
      decodedMap.forEach((name, rawList) {
        if (rawList is List) {
          final songs = rawList
              .whereType<Map<String, dynamic>>()
              .map(Song.fromJson)
              .where((song) => song.id.isNotEmpty)
              .toList();
          playlists[name] = _dedupeSongs(songs);
        }
      });
      return playlists;
    } catch (_) {
      return {};
    }
  }

  Map<String, List<Song>> _mergePlaylistMaps(
    List<Map<String, List<Song>>> maps,
  ) {
    final merged = <String, List<Song>>{};
    for (final map in maps) {
      map.forEach((name, songs) {
        final existing = merged[name] ?? const <Song>[];
        merged[name] = _dedupeSongs([...existing, ...songs]);
      });
    }
    return merged;
  }

  List<_HistoryEntry> _decodeHistoryEntries(List<String> encodedEntries) {
    final entries = <_HistoryEntry>[];
    for (final encoded in encodedEntries) {
      try {
        final decoded = jsonDecode(encoded);
        if (decoded is! Map<String, dynamic>) continue;

        final rawSong = decoded['song'];
        if (rawSong is! Map<String, dynamic>) continue;

        final song = Song.fromJson(rawSong);
        if (song.id.isEmpty) continue;

        entries.add(
          _HistoryEntry(
            song: song,
            playCount:
                int.tryParse(decoded['playCount']?.toString() ?? '1') ?? 1,
            firstPlayed:
                DateTime.tryParse(decoded['firstPlayed']?.toString() ?? '') ??
                    DateTime.fromMillisecondsSinceEpoch(0),
            lastPlayed:
                DateTime.tryParse(decoded['lastPlayed']?.toString() ?? '') ??
                    DateTime.fromMillisecondsSinceEpoch(0),
          ),
        );
      } catch (_) {}
    }
    return entries;
  }

  List<String> _encodeHistoryEntries(List<_HistoryEntry> entries) {
    return entries.map((entry) {
      return jsonEncode({
        'song': entry.song.toJson(),
        'playCount': entry.playCount,
        'firstPlayed': entry.firstPlayed.toIso8601String(),
        'lastPlayed': entry.lastPlayed.toIso8601String(),
      });
    }).toList();
  }

  List<_DownloadEntry> _decodeDownloadEntries(List<String> encodedEntries) {
    final entries = <_DownloadEntry>[];
    for (final encoded in encodedEntries) {
      try {
        final decoded = jsonDecode(encoded);
        if (decoded is! Map<String, dynamic>) continue;

        final rawSong = decoded['song'];
        if (rawSong is! Map<String, dynamic>) continue;

        final song = Song.fromJson(rawSong);
        final path = _clean(decoded['path']);
        if (song.id.isEmpty || path == null || path.isEmpty) continue;

        entries.add(
          _DownloadEntry(
            song: song,
            path: path,
            savedAt: DateTime.tryParse(decoded['savedAt']?.toString() ?? '') ??
                DateTime.fromMillisecondsSinceEpoch(0),
          ),
        );
      } catch (_) {}
    }
    return entries;
  }

  List<String> _encodeDownloadEntries(List<_DownloadEntry> entries) {
    return entries.map((entry) {
      return jsonEncode({
        'song': entry.song.toJson(),
        'path': entry.path,
        'savedAt': entry.savedAt.toIso8601String(),
      });
    }).toList();
  }

  String _songKey(Song song) => '${song.source}:${song.id}';

  String? _clean(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty || text == 'null' ? null : text;
  }
}

class _HistoryEntry {
  final Song song;
  final int playCount;
  final DateTime firstPlayed;
  final DateTime lastPlayed;

  const _HistoryEntry({
    required this.song,
    required this.playCount,
    required this.firstPlayed,
    required this.lastPlayed,
  });

  double get recommendationScore {
    final daysSincePlay = DateTime.now().difference(lastPlayed).inDays;
    final recency = 1 / (1 + daysSincePlay / 14);
    return playCount * 2.4 + recency * 7;
  }

  _HistoryEntry copyWith({
    Song? song,
    int? playCount,
    DateTime? firstPlayed,
    DateTime? lastPlayed,
  }) {
    return _HistoryEntry(
      song: song ?? this.song,
      playCount: playCount ?? this.playCount,
      firstPlayed: firstPlayed ?? this.firstPlayed,
      lastPlayed: lastPlayed ?? this.lastPlayed,
    );
  }
}

class _DownloadEntry {
  final Song song;
  final String path;
  final DateTime savedAt;

  const _DownloadEntry({
    required this.song,
    required this.path,
    required this.savedAt,
  });
}
