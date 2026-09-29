import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';

// Service that handles persistent on-device storage using SharedPreferences.
// Manages user favorites (likes), recently played history, search history,
// custom playlists, and offline downloaded song metadata.
class StorageService {
  // Key for storing the list of user's favorited / liked songs in JSON format.
  static const String _favoritesKey = 'user_favorites_tracks';

  // Key for storing the list of recently played songs.
  static const String _recentKey = 'user_recent_tracks';

  // Key for storing detailed listening history (including play counts and timestamps) used for recommendations.
  static const String _historyKey = 'user_listening_history_tracks';

  // Key for storing recent search queries submitted by the user.
  static const String _recentSearchesKey = 'user_recent_searches';

  // Key for storing user-created custom playlists and their songs.
  static const String _playlistsKey = 'user_custom_playlists';

  // Key for storing metadata and local file paths of songs downloaded for offline playback.
  static const String _downloadsKey = 'user_downloaded_tracks';

  // Legacy key for backward compatibility with older versions of the app storing liked songs.
  static const String _legacyFavoritesKey = 'liked_songs';

  // Legacy key for backward compatibility with older versions storing recently played songs.
  static const String _legacyRecentKey = 'recently_played';

  // Legacy key for backward compatibility with older versions storing custom playlists.
  static const String _legacyPlaylistsKey = 'playlists';

  // Checks whether a specific song (by its ID) is in the user's liked / favorites list.
  Future<bool> isLiked(String songId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Decode songs from both current and legacy storage keys to avoid losing past favorites.
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

  // Toggles the favorite status of a song: adds it if not present, or removes it if already liked.
  Future<void> toggleLike(Song song) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final songs = _decodeSongLists([
        prefs.getStringList(_favoritesKey) ?? const [],
        prefs.getStringList(_legacyFavoritesKey) ?? const [],
      ]);

      // Check if the song already exists in the liked list.
      final existingIndex = songs.indexWhere((item) => item.id == song.id);
      if (existingIndex >= 0) {
        // Song is already liked: remove it (unlike).
        songs.removeAt(existingIndex);
      } else {
        // Song is not liked: insert at the beginning of the list.
        songs.insert(0, song);
      }

      // Persist the updated list back to SharedPreferences.
      await _saveSongList(
        prefs,
        const [_favoritesKey, _legacyFavoritesKey],
        songs,
      );
    } catch (e) {
      debugPrint('Storage toggleLike error: $e');
    }
  }

  // Retrieves all liked songs from local storage, migrating legacy entries if found.
  Future<List<Song>> getLikedSongs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final songs = _decodeSongLists([
        prefs.getStringList(_favoritesKey) ?? const [],
        prefs.getStringList(_legacyFavoritesKey) ?? const [],
      ]);
      // If songs were loaded, re-save them to ensure both current and legacy keys are up-to-date.
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

  // Overwrites the entire liked songs list with a new deduplicated list of songs.
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

  Future<void>? _recentWriteLock;

  // Records that a song was played, moving it to the top of the recently played list
  // and incrementing its frequency in detailed listening history.
  Future<void> addRecentlyPlayed(Song song) async {
    while (_recentWriteLock != null) {
      await _recentWriteLock;
    }
    final completer = Completer<void>();
    _recentWriteLock = completer.future;

    try {
      final prefs = await SharedPreferences.getInstance();
      final songs = _decodeSongLists([
        prefs.getStringList(_recentKey) ?? const [],
        prefs.getStringList(_legacyRecentKey) ?? const [],
      ]);

      // Remove existing occurrence so we can move this track to the top (most recent).
      final existingIndex = songs.indexWhere((item) => _songKey(item) == _songKey(song));
      if (existingIndex >= 0) {
        final existing = songs[existingIndex];
        // If the existing record has a valid duration but the new one is 0, preserve the valid duration.
        if (existing.duration > 0 && song.duration == 0) {
          song = song.copyWith(duration: existing.duration);
        }
        songs.removeAt(existingIndex);
      }
      songs.insert(0, song);
      // Cap the recently played list to a maximum of 80 tracks to save memory.
      final capped = songs.length > 80 ? songs.sublist(0, 80) : songs;

      await _saveSongList(
        prefs,
        const [_recentKey, _legacyRecentKey],
        capped,
      );
      // Also update listening history statistics for algorithmic recommendations.
      await _saveListeningHistory(prefs, song);
    } catch (e) {
      debugPrint('Storage addRecentlyPlayed error: $e');
    } finally {
      _recentWriteLock = null;
      completer.complete();
    }
  }

  // Removes a specific song from the recently played list.
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

  // Retrieves the list of recently played songs from local storage.
  Future<List<Song>> getRecentlyPlayed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final songs = _decodeSongLists([
        prefs.getStringList(_recentKey) ?? const [],
        prefs.getStringList(_legacyRecentKey) ?? const [],
      ]);
      // Migrate and sync lists if items exist.
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

  // Persists a full list of recently played songs, capped at 80 items.
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

  // Prepends new songs to the existing recently played list without duplicates.
  Future<void> mergeRecentlyPlayed(List<Song> songs) async {
    if (songs.isEmpty) return;
    final existing = await getRecentlyPlayed();
    await saveRecentlyPlayed([...songs, ...existing]);
  }

  // Loads weighted listening history used to train and feed the recommendation engine.
  // Sorts tracks by a combination of play counts and recency, duplicating popular tracks
  // proportionally so the recommendation algorithm weights them higher.
  Future<List<Song>> getListeningHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final entries =
          _decodeHistoryEntries(prefs.getStringList(_historyKey) ?? []);

      // If no detailed history exists yet, fall back to basic recently played songs.
      if (entries.isEmpty) return getRecentlyPlayed();

      // Sort entries by recommendation score descending; break ties by last played date.
      entries.sort((a, b) {
        final scoreB = b.recommendationScore;
        final scoreA = a.recommendationScore;
        final scoreCompare = scoreB.compareTo(scoreA);
        if (scoreCompare != 0) return scoreCompare;
        return b.lastPlayed.compareTo(a.lastPlayed);
      });

      // Repeat songs with high play counts (up to 4 times) to weight them in seed analysis.
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

  // Retrieves the list of recent search query strings.
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

  // Adds a search term to recent searches, moving it to the top and capping at 15 items.
  Future<void> addRecentSearch(String query) async {
    try {
      final cleanQuery = query.trim();
      if (cleanQuery.isEmpty) return;

      final prefs = await SharedPreferences.getInstance();
      final searches = List<String>.from(
        prefs.getStringList(_recentSearchesKey) ?? const [],
      );
      // Remove any case-insensitive duplicate of the query.
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

  // Deletes all stored recent searches.
  Future<void> clearRecentSearches() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_recentSearchesKey);
    } catch (e) {
      debugPrint('Storage clearRecentSearches error: $e');
    }
  }

  // Deletes a single specific query from the recent searches list.
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

  // Retrieves all custom playlists and their associated lists of songs.
  // Merges modern and legacy storage entries to ensure no user playlists are lost.
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

  // Returns all Song objects that have been downloaded locally onto the device.
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

  // Returns a map linking song composite keys (source:id) to their local file paths on the device.
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

  // Looks up the local file system path for a specific downloaded song, if it exists.
  Future<String?> getDownloadPath(Song song) async {
    final paths = await getDownloadPaths();
    return paths[_songKey(song)];
  }

  // Verifies whether a song is saved locally AND the physical audio file actually exists on disk.
  Future<bool> isDownloaded(Song song) async {
    final path = await getDownloadPath(song);
    return path != null && await File(path).exists();
  }

  // Records a newly downloaded song into storage with its absolute local storage path.
  Future<void> saveDownloadedSong(Song song, String localPath) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final entries = _decodeDownloadEntries(
        prefs.getStringList(_downloadsKey) ?? [],
      )..removeWhere((entry) => _songKey(entry.song) == _songKey(song));

      // Add as the most recent download at the beginning of the list.
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

  // Removes a song from downloaded tracks storage and deletes the physical file from the device disk.
  Future<void> removeDownloadedSong(Song song) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final entries = _decodeDownloadEntries(
        prefs.getStringList(_downloadsKey) ?? [],
      );
      final removed = <_DownloadEntry>[];

      // Remove the matching entry from the in-memory list.
      entries.removeWhere((entry) {
        final matches = _songKey(entry.song) == _songKey(song);
        if (matches) removed.add(entry);
        return matches;
      });

      // Update the SharedPreferences list.
      await prefs.setStringList(_downloadsKey, _encodeDownloadEntries(entries));

      // Physically delete the local audio file from disk.
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

  // Creates a new empty user playlist under the given name if one does not already exist.
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

  // Deletes an entire user playlist by its name.
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

  // Renames an existing playlist while preserving all of its songs.
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

  // Adds a song to a user playlist, placing it at the front and avoiding duplicates.
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

  // Replaces the songs inside a named playlist with a new, deduplicated song list.
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

  // Merges new songs into an existing playlist without wiping existing tracks.
  Future<void> mergePlaylist(String name, List<Song> songs) async {
    if (songs.isEmpty) return;
    final playlists = await getPlaylists();
    final existing = playlists[name.trim()] ?? const <Song>[];
    await savePlaylist(name, [...songs, ...existing]);
  }

  // Removes a specific song from a user playlist.
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

  // Helper method to JSON-encode and persist the entire playlist map to both primary and legacy keys.
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

  // Updates frequency metrics and last-played timestamps whenever a song is played,
  // capping the history size to 300 entries to prevent memory bloating.
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
      // Existing song: increment its play count and update the last played timestamp.
      final existing = entries[index];
      entries[index] = existing.copyWith(
        song: song,
        playCount: existing.playCount + 1,
        lastPlayed: now,
      );
    } else {
      // New song: insert fresh entry with initial count of 1.
      entries.add(
        _HistoryEntry(
          song: song,
          playCount: 1,
          firstPlayed: now,
          lastPlayed: now,
        ),
      );
    }

    // Sort by play count descending, then by last played date.
    entries.sort((a, b) {
      final countCompare = b.playCount.compareTo(a.playCount);
      if (countCompare != 0) return countCompare;
      return b.lastPlayed.compareTo(a.lastPlayed);
    });

    // Keep at most 300 entries in history.
    final capped = entries.length > 300 ? entries.sublist(0, 300) : entries;
    await prefs.setStringList(_historyKey, _encodeHistoryEntries(capped));
  }

  // Deserializes a list of JSON string entries into Song model instances.
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

  // Decodes songs from multiple sources (such as current and legacy keys) and deduplicates them.
  List<Song> _decodeSongLists(List<List<String>> encodedLists) {
    final songs = <Song>[];
    for (final encoded in encodedLists) {
      songs.addAll(_decodeSongList(encoded));
    }
    return _dedupeSongs(songs);
  }

  // Removes duplicate songs from a list using their unique composite keys.
  List<Song> _dedupeSongs(List<Song> songs) {
    final seen = <String>{};
    final deduped = <Song>[];
    for (final song in songs) {
      final key = _songKey(song);
      if (seen.add(key)) deduped.add(song);
    }
    return deduped;
  }

  // Serializes and saves a list of songs into multiple SharedPreferences keys simultaneously.
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

  // Converts a list of Song objects into an array of JSON string representations.
  List<String> _encodeSongList(List<Song> songs) {
    return songs.map((song) => jsonEncode(song.toJson())).toList();
  }

  // Deserializes a JSON string representation into a map of playlist names to their song lists.
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

  // Combines multiple playlist maps (such as legacy and modern playlists) into a single map.
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

  // Deserializes stored JSON strings into detailed _HistoryEntry objects.
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

  // Serializes detailed history entries into an array of JSON strings for storage.
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

  // Deserializes stored JSON strings into offline download tracking records.
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

  // Serializes download records into JSON strings for local preferences storage.
  List<String> _encodeDownloadEntries(List<_DownloadEntry> entries) {
    return entries.map((entry) {
      return jsonEncode({
        'song': entry.song.toJson(),
        'path': entry.path,
        'savedAt': entry.savedAt.toIso8601String(),
      });
    }).toList();
  }

  // Generates a unique composite string key (format: 'source:id') for a song.
  String _songKey(Song song) => '${song.source}:${song.id}';

  // Sanitizes a dynamic value into a clean trimmed string, or null if empty or invalid.
  String? _clean(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty || text == 'null' ? null : text;
  }
}

// Data container tracking listening metrics for a specific song (play count, dates).
class _HistoryEntry {
  // The song model associated with this history item.
  final Song song;

  // Total number of times this track has been played by the user.
  final int playCount;

  // The timestamp when the user listened to this song for the very first time.
  final DateTime firstPlayed;

  // The timestamp when the user most recently listened to this song.
  final DateTime lastPlayed;

  // Constructor requiring all history entry parameters.
  const _HistoryEntry({
    required this.song,
    required this.playCount,
    required this.firstPlayed,
    required this.lastPlayed,
  });

  // Computes a weighted score balancing total play count and how recently the song was played.
  // Recently heard tracks and frequently played tracks receive the highest scores.
  double get recommendationScore {
    final daysSincePlay = DateTime.now().difference(lastPlayed).inDays;
    // Decays smoothly over a two-week period.
    final recency = 1 / (1 + daysSincePlay / 14);
    return playCount * 2.4 + recency * 7;
  }

  // Returns a copy of this history entry with updated fields.
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

// Data container representing an offline downloaded song on the local filesystem.
class _DownloadEntry {
  // Metadata for the downloaded track.
  final Song song;

  // The absolute file system path where the audio file is stored on the device.
  final String path;

  // The timestamp when the audio file was saved.
  final DateTime savedAt;

  // Constructor requiring the song, its local file path, and save timestamp.
  const _DownloadEntry({
    required this.song,
    required this.path,
    required this.savedAt,
  });
}
