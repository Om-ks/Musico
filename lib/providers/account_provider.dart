import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../screens/login_webview_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/account_library.dart';
import '../models/music_playlist.dart';
import '../models/song.dart';
import '../services/storage_service.dart';
import '../services/youtube_account_service.dart';
import '../services/api_service.dart';

enum AccountMode { guest, youtube }

class AccountProvider extends ChangeNotifier {
  static const String _authorizedKey = 'yt_authorized';
  static const String _cachedLibraryKey = 'cached_yt_library';
  static const String _cachedDisplayNameKey = 'yt_display_name';
  static const String _cachedEmailKey = 'yt_email';
  static const String _cachedPhotoUrlKey = 'yt_photo_url';
  static const String _lastSyncKey = 'yt_last_sync';
  static const String _playlistMappingsKey = 'yt_playlist_mappings';
  static const String _recentlyUnlikedKey = 'yt_recently_unliked';

  final YoutubeAccountService _youtubeAccountService = YoutubeAccountService();
  final StorageService _storage = StorageService();
  
  Map<String, String> _playlistMappings = {};
  late final Future<void> _ready;
  final Map<String, DateTime> _recentlyUnlikedSongs = {};

  String? _cookieString;
  String? _cachedDisplayName;
  String? _cachedEmail;
  String? _cachedPhotoUrl;
  AccountLibrary _library = AccountLibrary.empty;
  bool _initialized = false;
  bool _busy = false;
  bool _youtubeAuthorized = false;
  bool _syncingLibrary = false;
  String? _errorMessage;
  AccountMode _mode = AccountMode.guest;

  AccountProvider() {
    _ready = _init();
  }

  String? get cookieString => _cookieString;
  AccountLibrary get library => _library;
  bool get isSignedIn => _cookieString != null || _mode == AccountMode.youtube;
  bool get hasLiveSession => _cookieString != null;
  bool get isBusy => _busy;
  bool get isInitialized => _initialized;
  bool get youtubeAuthorized => _youtubeAuthorized;
  bool get needsReconnect => _mode == AccountMode.youtube && _cookieString == null;
  String? get errorMessage => _errorMessage;
  AccountMode get mode => _mode;
  String? get email => _cachedEmail;
  String? get photoUrl => _cachedPhotoUrl;

  String get displayName {
    if (_mode == AccountMode.guest && _cookieString == null) return 'Guest User';
    final cachedName = _cachedDisplayName?.trim();
    if (cachedName != null && cachedName.isNotEmpty) return cachedName;
    if (email != null) return email!;
    return 'Guest User';
  }

  String get statusText {
    if (_busy) return 'Syncing account...';
    if (_mode == AccountMode.guest) return 'Guest mode - Local storage';
    if (_youtubeAuthorized) {
      if (_syncingLibrary) return 'YouTube mode - Syncing...';

      final liked = _library.likedSongs.length;
      final playlists = _library.playlists.length;
      final session = _cookieString == null ? 'cached' : 'connected';

      if (liked == 0 && playlists == 0) {
        if (_errorMessage != null) return 'YouTube mode - $_errorMessage';
        return 'YouTube mode - $session - No music found';
      }
      return 'YouTube mode - $session - $liked liked, $playlists playlists';
    }
    return 'Signed in. YouTube access not linked yet.';
  }

  Future<void> signIn(BuildContext context) async {
    await _ready;
    await _runBusy(() async {
      try {
        _errorMessage = null;
        final cookie = await Navigator.of(context).push<String?>(
          MaterialPageRoute(builder: (_) => const LoginWebviewScreen()),
        );
        if (cookie != null && cookie.isNotEmpty) {
          await _setUser(
            cookie,
            fetchIfAuthorized: true,
            forceRefresh: true,
          );
        }
      } catch (e) {
        _errorMessage = e.toString();
        notifyListeners();
      }
    });
  }

  Future<void> connectYoutube(BuildContext context) async {
    await signIn(context);
  }

  Future<void> signOut() async {
    await _ready;
    await _runBusy(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('sapisid_cookie');
      } finally {
      }
      await _clearUser();
      _cachedDisplayName = null;
      _cachedEmail = null;
      _cachedPhotoUrl = null;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_authorizedKey, false);
      await prefs.remove(_lastSyncKey);
      notifyListeners();
    });
  }

  Future<void> _init() async {
    try {
      debugPrint('AccountProvider: Starting _init');
      final prefs = await SharedPreferences.getInstance();
      _youtubeAuthorized = prefs.getBool(_authorizedKey) ?? false;
      _cachedDisplayName = prefs.getString(_cachedDisplayNameKey);
      _cachedEmail = prefs.getString(_cachedEmailKey);
      _cachedPhotoUrl = prefs.getString(_cachedPhotoUrlKey);

      final mappingsStr = prefs.getString(_playlistMappingsKey);
      if (mappingsStr != null) {
        try {
          final decoded = jsonDecode(mappingsStr);
          if (decoded is Map) {
            _playlistMappings =
                decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
          }
        } catch (e) {
          debugPrint('Error loading playlist mappings: $e');
        }
      }

      final unlikedStr = prefs.getString(_recentlyUnlikedKey);
      if (unlikedStr != null) {
        try {
          final decoded = jsonDecode(unlikedStr);
          if (decoded is Map) {
            final now = DateTime.now();
            decoded.forEach((k, v) {
              final time = DateTime.fromMillisecondsSinceEpoch(v as int);
              // Only keep if within last 2 hours
              if (now.difference(time).inMinutes < 120) {
                _recentlyUnlikedSongs[k.toString()] = time;
              }
            });
          }
        } catch (e) {
          debugPrint('Error loading recently unliked: $e');
        }
      }

      if (_youtubeAuthorized) {
        _restoreCachedLibrary(prefs);
      }

      if (_youtubeAuthorized) {
        _mode = AccountMode.youtube;
      }

      final savedCookie = prefs.getString('sapisid_cookie');
      if (savedCookie != null && savedCookie.isNotEmpty) {
        await _setUser(
          savedCookie,
          fetchIfAuthorized: _youtubeAuthorized,
          forceRefresh: false,
        );
      } else if (_youtubeAuthorized) {
        _mode = AccountMode.youtube;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('AccountProvider init error: $e');
    } finally {
      debugPrint('AccountProvider: _init complete');
      _initialized = true;
      notifyListeners();
    }
  }


  void _restoreCachedLibrary(SharedPreferences prefs) {
    final cachedLib = prefs.getString(_cachedLibraryKey);
    if (cachedLib == null) return;
    try {
      final data = jsonDecode(cachedLib);
      _library = AccountLibrary(
        likedSongs: _songsFromCachedList(data['liked']),
        recentSongs: _songsFromCachedList(data['recent']),
        playlists: _playlistsFromCachedList(data['playlists']),
      );
    } catch (e) {
      debugPrint('Error loading cached library: $e');
    }
  }



  Future<void> _cacheLibrary() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = {
        'liked': _library.likedSongs.map((s) => s.toJson()).toList(),
        'recent': _library.recentSongs.map((s) => s.toJson()).toList(),
        'playlists': _library.playlists
            .map((p) => {
                  'id': p.id,
                  'title': p.title,
                  'owner': p.owner,
                  'thumbnailUrl': p.thumbnailUrl,
                  'itemCount': p.itemCount,
                  'source': p.source,
                  'songs': [],
                })
            .toList(),
      };
      await prefs.setString(_cachedLibraryKey, jsonEncode(data));
    } catch (e) {
      debugPrint('Error caching library: $e');
    }
  }

  List<Song> _songsFromCachedList(dynamic list) {
    if (list is! List) return [];
    return list
        .map((item) => Song.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  List<MusicPlaylist> _playlistsFromCachedList(dynamic list) {
    if (list is! List) return [];
    return list.map((item) {
      final map = item as Map<String, dynamic>;
      return MusicPlaylist(
        id: map['id'] as String,
        title: map['title'] as String,
        owner: map['owner'] as String,
        thumbnailUrl: map['thumbnailUrl'] as String,
        itemCount: map['itemCount'] as int,
        source: map['source'] as String,
      );
    }).toList();
  }

  final Map<String, DateTime> _recentlyAddedSongsToPlaylists = {};

  void recordPlaylistSongAddition(String playlistId, String songId) {
    _recentlyAddedSongsToPlaylists['$playlistId:$songId'] = DateTime.now();
  }

  void toggleLocalLikedState(Song song, bool liked) {
    final list = List<Song>.from(_library.likedSongs);
    if (liked) {
      if (!list.any((s) => s.id == song.id)) {
        list.insert(0, song);
      }
      _recentlyUnlikedSongs.remove(song.id);
    } else {
      list.removeWhere((s) => s.id == song.id);
      _recentlyUnlikedSongs[song.id] = DateTime.now();
    }
    _library = AccountLibrary(
      likedSongs: list,
      recentSongs: _library.recentSongs,
      playlists: _library.playlists,
    );
    notifyListeners();
    unawaited(_cacheLibrary());
    unawaited(_saveRecentlyUnliked());
  }

  Future<void> _saveRecentlyUnliked() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final mapToSave = _recentlyUnlikedSongs.map((k, v) => MapEntry(k, v.millisecondsSinceEpoch));
      await prefs.setString(_recentlyUnlikedKey, jsonEncode(mapToSave));
    } catch (e) {
      debugPrint('Error saving recently unliked: $e');
    }
  }

  Future<AccountLibrary> _mergeAndPushLocalLibrary(
    Map<String, String> headers,
    AccountLibrary remote,
  ) async {
    debugPrint('AccountProvider: Merging libraries...');

    // 1. Merge Liked Songs. Keep the last stable local order, add new remote
    // likes from YouTube, and retry local-only likes back to YouTube.
    final localLiked = await _storage.getLikedSongs();
    final mergedLiked = _mergeLikedSongsPreservingOrder(
      headers: headers,
      localLiked: localLiked,
      remoteLiked: remote.likedSongs,
    );
    await _storage.saveLikedSongs(mergedLiked);

    // 2. Merge Playlists (Crucial optimization: avoid fetching ALL playlists repeatedly)
    final localPlaylists = await _storage.getPlaylists();
    final mergedPlaylists = <MusicPlaylist>[...remote.playlists];

    for (final entry in localPlaylists.entries) {
      final name = entry.key;
      final localSongs = entry.value;

      // Check if playlist exists in the already-fetched remote list
      var remotePlaylist = mergedPlaylists.firstWhere(
        (p) => p.title.trim().toLowerCase() == name.trim().toLowerCase(),
        orElse: () => const MusicPlaylist(
            id: '',
            title: '',
            owner: '',
            thumbnailUrl: '',
            itemCount: 0,
            source: ''),
      );

      // Check SharedPreferences mapped cache if remotePlaylist wasn't found in remote.playlists
      if (remotePlaylist.id.isEmpty) {
        final key = name.trim().toLowerCase();
        final cachedId = _playlistMappings[key];
        if (cachedId != null && cachedId.isNotEmpty) {
          debugPrint(
              'AccountProvider: Found cached playlist ID $cachedId for "$name"');
          remotePlaylist = MusicPlaylist(
            id: cachedId,
            title: name,
            owner: 'Me',
            thumbnailUrl: '',
            itemCount: localSongs.length,
            source: 'youtube',
          );
          if (!mergedPlaylists.any((p) => p.id == cachedId)) {
            mergedPlaylists.add(remotePlaylist);
          }
        }
      }

      // If still not found, try to ensure it (creates if missing)
      if (remotePlaylist.id.isEmpty) {
        debugPrint(
            'AccountProvider: Playlist "$name" not found in remote list or cache, ensuring...');
        remotePlaylist =
            await _youtubeAccountService.ensurePlaylist(headers, name) ??
                const MusicPlaylist(
                    id: '',
                    title: '',
                    owner: '',
                    thumbnailUrl: '',
                    itemCount: 0,
                    source: '');

        if (remotePlaylist.id.isNotEmpty) {
          _playlistMappings[name.trim().toLowerCase()] = remotePlaylist.id;
          unawaited(_savePlaylistMappings());

          if (!mergedPlaylists.any((p) => p.id == remotePlaylist.id)) {
            mergedPlaylists.add(remotePlaylist);
          }
        }
      }

      // Sync songs to the playlist
      if (remotePlaylist.id.isNotEmpty) {
        final remoteSongs = await _youtubeAccountService
            .fetchPlaylistSongs(
              headers,
              remotePlaylist.id,
              album: name,
            )
            .timeout(const Duration(seconds: 15))
            .catchError((_) => <Song>[]);

        final remoteSongIds = remoteSongs.map((s) => s.id).toSet();
        int addedToPlaylist = 0;
        for (final song in localSongs) {
          if (song.source == 'youtube' && !remoteSongIds.contains(song.id)) {
            // Check if recently added to avoid YouTube cache latency duplication
            final key = '${remotePlaylist.id}:${song.id}';
            final recentlyAdded = _recentlyAddedSongsToPlaylists[key];
            if (recentlyAdded != null &&
                DateTime.now().difference(recentlyAdded).inMinutes < 5) {
              debugPrint(
                  'AccountProvider: Skipping duplicate add for song ${song.title} to playlist "$name" (added recently).');
              continue;
            }

            unawaited(_youtubeAccountService.addSongToPlaylist(
                headers, remotePlaylist.id, song.id));
            recordPlaylistSongAddition(remotePlaylist.id, song.id);
            addedToPlaylist++;
          }
        }
        if (addedToPlaylist > 0) {
          debugPrint(
              'AccountProvider: Added $addedToPlaylist songs to remote playlist "$name".');
        }
      }
    }

    final localRecents = await _storage.getRecentlyPlayed();
    final mergedRecents =
        <Song>{...remote.recentSongs, ...localRecents}.toList();
    await _storage.saveRecentlyPlayed(mergedRecents);

    return AccountLibrary(
      likedSongs: mergedLiked,
      recentSongs: mergedRecents,
      playlists: mergedPlaylists,
    );
  }

  Future<MusicPlaylist?> _ensureYoutubePlaylist(
      Map<String, String> headers, String name) async {
    final key = name.trim().toLowerCase();
    final cachedId = _playlistMappings[key];
    if (cachedId != null && cachedId.isNotEmpty) {
      return MusicPlaylist(
        id: cachedId,
        title: name,
        owner: 'Me',
        thumbnailUrl: '',
        itemCount: 0,
        source: 'youtube',
      );
    }
    final playlist = await _youtubeAccountService.ensurePlaylist(headers, name);
    if (playlist != null) {
      _playlistMappings[key] = playlist.id;
      unawaited(_savePlaylistMappings());
    }
    return playlist;
  }

  Future<MusicPlaylist?> _findYoutubePlaylist(
      Map<String, String> headers, String name) async {
    final key = name.trim().toLowerCase();
    final cachedId = _playlistMappings[key];
    if (cachedId != null && cachedId.isNotEmpty) {
      return MusicPlaylist(
        id: cachedId,
        title: name,
        owner: 'Me',
        thumbnailUrl: '',
        itemCount: 0,
        source: 'youtube',
      );
    }
    final playlist =
        await _youtubeAccountService.findPlaylistByName(headers, name);
    if (playlist != null) {
      _playlistMappings[key] = playlist.id;
      unawaited(_savePlaylistMappings());
    }
    return playlist;
  }

  Future<void> _savePlaylistMappings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _playlistMappingsKey, jsonEncode(_playlistMappings));
    } catch (e) {
      debugPrint('Error saving playlist mappings: $e');
    }
  }

  String _songKey(Song song) => '${song.source}:${song.id}';

  List<Song> _mergeLikedSongsPreservingOrder({
    required Map<String, String> headers,
    required List<Song> localLiked,
    required List<Song> remoteLiked,
  }) {
    bool removedAny = false;
    _recentlyUnlikedSongs.removeWhere((_, time) {
      final old = DateTime.now().difference(time).inMinutes > 120; // 2 hours
      if (old) removedAny = true;
      return old;
    });
    if (removedAny) unawaited(_saveRecentlyUnliked());

    final filteredRemoteLiked = remoteLiked.where((s) => !_recentlyUnlikedSongs.containsKey(s.id)).toList();

    if (filteredRemoteLiked.isEmpty) return _dedupeSongs(localLiked);
    if (localLiked.isEmpty) return _dedupeSongs(filteredRemoteLiked);

    final remoteKeys = filteredRemoteLiked.map(_songKey).toSet();

    var pushedLikes = 0;
    for (final song in localLiked) {
      if (song.source == 'youtube' && !remoteKeys.contains(_songKey(song))) {
        unawaited(_youtubeAccountService.rateSong(headers, song.id, 'like'));
        pushedLikes++;
      }
    }
    if (pushedLikes > 0) {
      debugPrint(
        'AccountProvider: Retried $pushedLikes local likes to YouTube.',
      );
    }

    // Preserve local order: 
    // 1. New remote likes go to the top
    // 2. Existing likes stay in their local order
    final localKeys = localLiked.map(_songKey).toSet();
    final newRemoteLikes = filteredRemoteLiked
        .where((song) => !localKeys.contains(_songKey(song)))
        .toList(growable: false);

    final preservedLocalLikes = localLiked
        .where((song) => remoteKeys.contains(_songKey(song)) || !remoteKeys.contains(_songKey(song))) // Keep all local, but we know if it was removed remotely, wait, if it was removed remotely and NOT recently unliked, we shouldn't keep it unless we pushed it.
        // Actually, if it's local but not remote, we just pushed it, so we keep it.
        // Wait, if it was unliked on another device, it won't be in remote. We will re-push it!
        // That's a known limitation of offline sync without proper tombstones.
        .toList(growable: false);

    return _dedupeSongs([...newRemoteLikes, ...preservedLocalLikes]);
  }

  Future<void> _clearUser() async {
    _cookieString = null;
    _youtubeAuthorized = false;
    _mode = AccountMode.guest;
    _library = AccountLibrary.empty;
    _playlistMappings.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cachedLibraryKey);
    await prefs.remove(_playlistMappingsKey);
    await prefs.remove(_cachedDisplayNameKey);
    await prefs.remove(_cachedEmailKey);
    await prefs.remove(_cachedPhotoUrlKey);
    await prefs.setBool(_authorizedKey, false);
    notifyListeners();
  }

  Future<void> _runBusy(Future<void> Function() work) async {
    if (_busy) return;
    _busy = true;
    notifyListeners();
    try {
      await work();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  List<Song> _dedupeSongs(List<Song> songs) {
    final seen = <String>{};
    final deduped = <Song>[];
    for (final song in songs) {
      if (song.id.isEmpty) continue;
      if (seen.add(_songKey(song))) deduped.add(song);
    }
    return deduped;
  }

  Future<void> _setUser(
    String cookie, {
    bool fetchIfAuthorized = false,
    bool forceRefresh = false,
  }) async {
    _cookieString = cookie;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('sapisid_cookie', cookie);

    if (_library.likedSongs.isEmpty && _library.playlists.isEmpty) {
      _restoreCachedLibrary(prefs);
    }

    _youtubeAuthorized = true;
    _mode = AccountMode.youtube;
    await prefs.setBool(_authorizedKey, true);
    if (fetchIfAuthorized && (forceRefresh || await _shouldSync())) {
      await refreshLibrary(force: forceRefresh);
    }
    notifyListeners();
  }

  Future<bool> _shouldSync() async {
    final prefs = await SharedPreferences.getInstance();
    final lastSync = prefs.getInt(_lastSyncKey) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;

    // If library is empty, we must sync
    if (_library.likedSongs.isEmpty && _library.playlists.isEmpty) return true;

    // Auto-sync every 2 hours (more frequent than 4)
    return (now - lastSync) > 1000 * 60 * 60 * 2;
  }

  Future<void> refreshLibrary({bool force = false}) async {
    final account = _cookieString;
    if (account == null || !_youtubeAuthorized) return;
    if (_syncingLibrary && !force) return;

    if (!force && !await _shouldSync()) {
      debugPrint('AccountProvider: Sync interval not reached, skipping.');
      return;
    }

    await _runBusy(() async {
      _syncingLibrary = true;
      _errorMessage = null; // Clear previous errors
      try {
        debugPrint('AccountProvider: Starting library refresh...');
        final headers = await getAuthHeaders();
        if (headers != null && headers.isNotEmpty) {
          final newLib = await _youtubeAccountService.fetchLibrary(headers);

          if (newLib.likedSongs.isEmpty && newLib.playlists.isEmpty) {
            debugPrint('AccountProvider: Fetched library is empty.');
            if (_library.likedSongs.isNotEmpty ||
                _library.playlists.isNotEmpty) {
              _errorMessage = 'Using cached library; refresh returned empty.';
              return;
            }
          }

          // Use a timeout for the heavy merge operation
          _library = await _mergeAndPushLocalLibrary(headers, newLib)
              .timeout(const Duration(seconds: 150));

          await _cacheLibrary();

          final prefs = await SharedPreferences.getInstance();
          await prefs.setInt(
              _lastSyncKey, DateTime.now().millisecondsSinceEpoch);
          debugPrint(
              'AccountProvider: Library sync complete. Liked: ${_library.likedSongs.length}');
        } else {
          _errorMessage = 'Could not get YouTube permissions.';
        }
      } catch (e) {
        debugPrint('Library refresh failed: $e');
        _errorMessage = 'Sync failed: ${e.toString()}';
      } finally {
        _syncingLibrary = false;
        notifyListeners();
      }
    });
  }

  Future<void> addSongToSyncedPlaylist(String playlistName, Song song) async {
    if (song.source != 'youtube') return;
    final headers = await getAuthHeaders();
    if (headers == null) return;

    try {
      final playlist = await _ensureYoutubePlaylist(headers, playlistName);
      if (playlist == null) return;

      final remoteSongs = await _youtubeAccountService.fetchPlaylistSongs(
        headers,
        playlist.id,
        album: playlist.title,
        maxPages: 100,
      );
      final exists =
          remoteSongs.any((item) => _songKey(item) == _songKey(song));
      if (!exists) {
        final added = await _youtubeAccountService.addSongToPlaylist(
          headers,
          playlist.id,
          song.id,
        );
        if (added) unawaited(refreshLibrary());
      }
    } catch (e) {
      debugPrint('Synced playlist add failed: $e');
    }
  }

  Future<void> removeSongFromSyncedPlaylist(
    String playlistName,
    Song song,
  ) async {
    if (song.source != 'youtube') return;
    final headers = await getAuthHeaders();
    if (headers == null) return;

    try {
      final playlist = await _findYoutubePlaylist(headers, playlistName);
      if (playlist == null) return;
      final removed = await _youtubeAccountService.removeSongFromPlaylist(
        headers,
        playlist.id,
        song.id,
      );
      if (removed) unawaited(refreshLibrary());
    } catch (e) {
      debugPrint('Synced playlist remove failed: $e');
    }
  }

  Future<Map<String, String>?> getAuthHeaders() async {
    final cookie = _cookieString;
    if (cookie == null || cookie.isEmpty) return null;
    return {'Cookie': cookie};
  }

  Future<HomeFeedData> fetchHomeFeed() async {
    final headers = await getAuthHeaders();
    if (headers == null) return const HomeFeedData(chips: [], sections: []);
    return await _youtubeAccountService.fetchHomeFeed(headers);
  }

  @override
  void dispose() {
    super.dispose();
  }
}
