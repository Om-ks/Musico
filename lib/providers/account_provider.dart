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

// Represents the current user login mode:
// - guest: Songs and playlists are saved locally on the device only.
// - youtube: Connected to YouTube Music account with cloud synchronization.
enum AccountMode { guest, youtube }

// Provider class that manages user authentication, account details, and library synchronization.
//
// Extends ChangeNotifier so the UI can listen for changes (such as login state, sync progress,
// or library updates) and rebuild automatically when notifyListeners() is called.
class AccountProvider extends ChangeNotifier {
  // SharedPreferences storage keys used to persist account session data between app launches.
  static const String _authorizedKey = 'yt_authorized';
  static const String _cachedLibraryKey = 'cached_yt_library';
  static const String _cachedDisplayNameKey = 'yt_display_name';
  static const String _cachedEmailKey = 'yt_email';
  static const String _cachedPhotoUrlKey = 'yt_photo_url';
  static const String _lastSyncKey = 'yt_last_sync';
  static const String _playlistMappingsKey = 'yt_playlist_mappings';
  static const String _recentlyUnlikedKey = 'yt_recently_unliked';

  // Tracks playlist IDs that were deleted during this app session so local sync doesn't revive them.
  final Set<String> _deletedPlaylists = {};

  // Service responsible for communicating with YouTube Music APIs (fetching library, liking songs, etc.).
  final YoutubeAccountService _youtubeAccountService = YoutubeAccountService();

  // Local storage service for saving songs, playlists, and recents to the device disk.
  final StorageService _storage = StorageService();
  
  // Maps playlist names to remote YouTube playlist IDs to avoid redundant API lookups or creations.
  Map<String, String> _playlistMappings = {};

  // A Future that completes once _init() has finished restoring cached credentials and data.
  late final Future<void> _ready;

  // Temporarily stores recently unliked song IDs with timestamps to prevent YouTube's
  // eventual-consistency latency from re-adding them during library synchronization.
  final Map<String, DateTime> _recentlyUnlikedSongs = {};

  // The active session cookie captured from Google login webview.
  String? _cookieString;

  // Cached user profile information.
  String? _cachedDisplayName;
  String? _cachedEmail;
  String? _cachedPhotoUrl;

  // In-memory representation of the user's music library (liked songs, recents, playlists).
  AccountLibrary _library = AccountLibrary.empty;

  // Indicates whether initial data loading from SharedPreferences has finished.
  bool _initialized = false;

  // True while a background login or sync task is running, used to show loading indicators.
  bool _busy = false;

  // True if the user has authenticated their YouTube account.
  bool _youtubeAuthorized = false;

  // True while actively syncing remote YouTube library with local storage.
  bool _syncingLibrary = false;

  // Holds any error message encountered during account operations to display to the user.
  String? _errorMessage;

  // Current mode: defaults to guest until authenticated.
  AccountMode _mode = AccountMode.guest;

  // Constructor initializes provider and starts loading cached session data.
  AccountProvider() {
    _ready = _init();
  }

  // Resolves when _init() completes (cookie and library loaded from SharedPreferences).
  Future<void> get ready => _ready;

  // Current session cookie string.
  String? get cookieString => _cookieString;

  // Current user's library containing liked songs, recents, and playlists.
  AccountLibrary get library => _library;

  // True if the user is signed in with a cookie or in YouTube mode.
  bool get isSignedIn => _cookieString != null || _mode == AccountMode.youtube;

  // True if there is an active, valid session cookie currently available.
  bool get hasLiveSession => _cookieString != null;

  // True if an account task (like syncing or logging in) is actively in progress.
  bool get isBusy => _busy;

  // True once the provider has finished reading saved data on startup.
  bool get isInitialized => _initialized;

  // True if YouTube account access is linked and authorized.
  bool get youtubeAuthorized => _youtubeAuthorized;

  // True if the user was previously linked to YouTube but their session cookie expired.
  bool get needsReconnect => _mode == AccountMode.youtube && _cookieString == null;

  // Recent error message, if any occurred.
  String? get errorMessage => _errorMessage;

  // Current account mode (guest or youtube).
  AccountMode get mode => _mode;

  // User's Google account email, if available.
  String? get email => _cachedEmail;

  // User's Google account avatar URL, if available.
  String? get photoUrl => _cachedPhotoUrl;

  // The formatted display name for the user (e.g. Profile name, email, or 'Guest User').
  String get displayName {
    if (_mode == AccountMode.guest && _cookieString == null) return 'Guest User';
    final cachedName = _cachedDisplayName?.trim();
    if (cachedName != null && cachedName.isNotEmpty) return cachedName;
    if (email != null) return email!;
    return _mode == AccountMode.youtube ? 'YouTube Music User' : 'Guest User';
  }

  // Generates a human-friendly status string describing the account connection and library sync state.
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

  // Initiates connecting a YouTube Music account.
  // Checks if an authentication cookie was previously saved. If so, shows a dialog giving
  // the user the choice to resume that account or log into a new one with clean cookies.
  Future<void> connectYoutube(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    final savedCookie = prefs.getString('sapisid_cookie');
    
    // If a saved cookie already exists, let the user pick between resuming or logging in fresh.
    if (savedCookie != null && savedCookie.isNotEmpty) {
      if (!context.mounted) return;
      final result = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1E1E28),
          title: const Text('Account Login', style: TextStyle(color: Colors.white)),
          content: const Text('Do you want to continue with your previously used account, or sign in to a new one?', style: TextStyle(color: Colors.white70)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'previous'),
              child: const Text('Previous Account', style: TextStyle(color: Colors.blueAccent)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'new'),
              child: const Text('New Account', style: TextStyle(color: Colors.blueAccent)),
            ),
          ],
        ),
      );
      
      // User chose to resume their previous account session without re-entering credentials.
      if (result == 'previous') {
        await _setUser(savedCookie, fetchIfAuthorized: true, forceRefresh: false);
        return;
      } else if (result == 'new') {
        // User chose to sign in with a new account; clear old cookies first.
        await _clearUser();
        if (!context.mounted) return;
        final cookie = await Navigator.of(context).push<String?>(
          MaterialPageRoute(builder: (_) => const LoginWebviewScreen(clearCookies: true)),
        );
        if (cookie != null && cookie.isNotEmpty) {
          await _setUser(cookie, fetchIfAuthorized: true, forceRefresh: true);
        }
        return;
      } else {
        return; // User dismissed/canceled the dialog.
      }
    }
    
    // No saved cookie found; open standard login webview directly.
    if (!context.mounted) return;
    await signIn(context);
  }

  // Opens the in-app Google Login webview to capture session cookies.
  // Upon successful login, sets the active user cookie and triggers library refresh.
  Future<void> signIn(BuildContext context) async {
    if (_busy) return;
    try {
      _errorMessage = null;
      // Push the webview screen and await returned authentication cookie.
      final cookie = await Navigator.of(context).push<String?>(
        MaterialPageRoute(builder: (_) => const LoginWebviewScreen(clearCookies: false)),
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
  }

  // Signs the user out of their YouTube account and switches the app back to local guest mode.
  // Updates persistent preferences so guest mode is retained upon next startup.
  Future<void> signOut() async {
    _youtubeAuthorized = false;
    _mode = AccountMode.guest;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_authorizedKey, false);
    notifyListeners();
  }

  // Initializes the provider during app startup.
  // Restores persisted authentication state, cached cookies, user profile details,
  // playlist mappings, and the offline library cache so UI shows instant data.
  Future<void> _init() async {
    try {
      debugPrint('AccountProvider: Starting _init');
      final prefs = await SharedPreferences.getInstance();
      // Load authorization flag and stored session credentials.
      _youtubeAuthorized = prefs.getBool(_authorizedKey) ?? false;
      _cookieString = prefs.getString('sapisid_cookie');
      _cachedDisplayName = prefs.getString(_cachedDisplayNameKey);
      _cachedEmail = prefs.getString(_cachedEmailKey);
      _cachedPhotoUrl = prefs.getString(_cachedPhotoUrlKey);
      
      // If user was previously authorized, default mode to YouTube.
      if (_youtubeAuthorized) {
        _mode = AccountMode.youtube;
      }

      // Restore playlist name-to-ID mappings from JSON string.
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

      // Restore recently unliked songs map (filtering out entries older than 2 hours).
      final unlikedStr = prefs.getString(_recentlyUnlikedKey);
      if (unlikedStr != null) {
        try {
          final decoded = jsonDecode(unlikedStr);
          if (decoded is Map) {
            final now = DateTime.now();
            decoded.forEach((k, v) {
              final time = DateTime.fromMillisecondsSinceEpoch(v as int);
              // Only keep entries within the last 2 hours (120 minutes)
              if (now.difference(time).inMinutes < 120) {
                _recentlyUnlikedSongs[k.toString()] = time;
              }
            });
          }
        } catch (e) {
          debugPrint('Error loading recently unliked: $e');
        }
      }

      // Restore the cached music library for fast offline-first rendering.
      if (_youtubeAuthorized) {
        _restoreCachedLibrary(prefs);
      }

      if (_youtubeAuthorized) {
        _mode = AccountMode.youtube;
      }

      // If a saved cookie is present, set up the user session; otherwise alert listeners.
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
      // Mark initialization complete so waiting widgets know data is ready.
      _initialized = true;
      notifyListeners();
    }
  }

  // Restores the offline cached music library from SharedPreferences.
  // Decodes saved JSON into liked tracks, recents, and playlists so content is visible instantly.
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



  // Saves the current in-memory library (liked songs, recent songs, and playlists) to local storage.
  // Encodes the library as JSON into SharedPreferences for fast offline retrieval.
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

  // Deserializes a raw JSON list into a list of Song model objects.
  List<Song> _songsFromCachedList(dynamic list) {
    if (list is! List) return [];
    return list
        .map((item) => Song.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  // Deserializes a raw JSON list into a list of MusicPlaylist model objects.
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

  // Cache of recently added playlist song combinations ('playlistId:songId' -> timestamp).
  // Helps prevent duplicate adds due to YouTube's eventual-consistency caching delay.
  final Map<String, DateTime> _recentlyAddedSongsToPlaylists = {};

  // Records that a song was added to a specific playlist at this moment.
  void recordPlaylistSongAddition(String playlistId, String songId) {
    _recentlyAddedSongsToPlaylists['$playlistId:$songId'] = DateTime.now();
  }

  // Optimistically updates the liked state of a song in memory immediately for instantaneous UI feedback.
  // If liked, inserts the song at the beginning of the list; if unliked, removes it and logs timestamp.
  void toggleLocalLikedState(Song song, bool liked) {
    final list = List<Song>.from(_library.likedSongs);
    if (liked) {
      // Add song to the beginning of the liked list if not already present.
      if (!list.any((s) => s.id == song.id)) {
        list.insert(0, song);
      }
      _recentlyUnlikedSongs.remove(song.id);
    } else {
      // Remove song from liked list and record the time it was unliked.
      list.removeWhere((s) => s.id == song.id);
      _recentlyUnlikedSongs[song.id] = DateTime.now();
    }
    // Update the immutable library instance with the new list.
    _library = AccountLibrary(
      likedSongs: list,
      recentSongs: _library.recentSongs,
      playlists: _library.playlists,
    );
    notifyListeners();
    // Persist changes to disk asynchronously without blocking the UI thread.
    unawaited(_cacheLibrary());
    unawaited(_saveRecentlyUnliked());
  }

  // Called after the Liked playlist directly fetches all songs from YouTube.
  // Syncs those songs into the app library so the Library tab immediately reflects them.
  void updateLikedSongsFromDirectFetch(List<Song> songs) {
    if (songs.isEmpty) return;
    _library = AccountLibrary(
      likedSongs: songs,
      recentSongs: _library.recentSongs,
      playlists: _library.playlists,
    );
    notifyListeners();
    unawaited(_cacheLibrary());
  }

  // Persists the recently unliked songs map to SharedPreferences as millisecond timestamps.
  Future<void> _saveRecentlyUnliked() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final mapToSave = _recentlyUnlikedSongs.map((k, v) => MapEntry(k, v.millisecondsSinceEpoch));
      await prefs.setString(_recentlyUnlikedKey, jsonEncode(mapToSave));
    } catch (e) {
      debugPrint('Error saving recently unliked: $e');
    }
  }

  // Performs two-way synchronization between local device storage and the remote YouTube Music account.
  // 1. Merges liked songs: respects remote ordering while filtering out any tracks unliked locally.
  // 2. Merges playlists: creates missing remote playlists for local ones and uploads unsynced songs.
  // 3. Merges listening history: combines local and remote recently played lists.
  // Returns the consolidated AccountLibrary.
  Future<AccountLibrary> _mergeAndPushLocalLibrary(
    Map<String, String> headers,
    AccountLibrary remote,
  ) async {
    debugPrint('AccountProvider: Merging libraries...');

    // 1. Merge Liked Songs: filter out locally unliked songs, preserving YouTube's sorting order.
    final mergedLiked = _mergeLikedSongs(remote.likedSongs);
    await _storage.saveLikedSongs(mergedLiked);

    // 2. Merge Playlists: exclude playlists that the user marked for deletion in this session.
    final localPlaylists = await _storage.getPlaylists();
    final mergedPlaylists = <MusicPlaylist>[
      ...remote.playlists.where((p) => !_deletedPlaylists.contains(p.id))
    ];

    // Check each locally saved playlist against remote YouTube playlists.
    for (final entry in localPlaylists.entries) {
      final name = entry.key;
      final localSongs = entry.value;

      // Check if this playlist already exists in the fetched remote list by title.
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

      // If not in the fetched list, check if we previously mapped its ID in SharedPreferences.
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
          // Add to merged list if not already present.
          if (!mergedPlaylists.any((p) => p.id == cachedId)) {
            mergedPlaylists.add(remotePlaylist);
          }
        }
      }

      // If still not found, create a new playlist with this name on YouTube.
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
          // Cache the new playlist mapping to prevent future duplicate creations.
          _playlistMappings[name.trim().toLowerCase()] = remotePlaylist.id;
          unawaited(_savePlaylistMappings());

          if (!mergedPlaylists.any((p) => p.id == remotePlaylist.id)) {
            mergedPlaylists.add(remotePlaylist);
          }
        }
      }

      // Sync individual songs into the remote YouTube playlist.
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
          // Only sync YouTube tracks that don't already exist on the remote playlist.
          if (song.source == 'youtube' && !remoteSongIds.contains(song.id)) {
            // Guard: check if recently added to avoid race conditions with YouTube's indexing delay.
            final key = '${remotePlaylist.id}:${song.id}';
            final recentlyAdded = _recentlyAddedSongsToPlaylists[key];
            if (recentlyAdded != null &&
                DateTime.now().difference(recentlyAdded).inMinutes < 5) {
              debugPrint(
                  'AccountProvider: Skipping duplicate add for song ${song.title} to playlist "$name" (added recently).');
              continue;
            }

            // Upload song to YouTube playlist in the background.
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

    // 3. Merge listening history: combine local and remote recents into a deduplicated list.
    final localRecents = await _storage.getRecentlyPlayed();
    final mergedRecents =
        <Song>{...localRecents, ...remote.recentSongs}.toList();
    await _storage.saveRecentlyPlayed(mergedRecents);

    // Return the newly merged, complete library.
    return AccountLibrary(
      likedSongs: mergedLiked,
      recentSongs: mergedRecents,
      playlists: mergedPlaylists,
    );
  }

  // Ensures that a playlist with the given name exists on YouTube.
  // Checks memory/disk mappings first; if not found, creates it on YouTube and caches its ID.
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

  // Searches for an existing YouTube playlist by name without creating one.
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

  // Persists the in-memory playlist name-to-ID mappings map into SharedPreferences.
  Future<void> _savePlaylistMappings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _playlistMappingsKey, jsonEncode(_playlistMappings));
    } catch (e) {
      debugPrint('Error saving playlist mappings: $e');
    }
  }

  // Generates a composite string key for a song ('source:id') for easy lookups.
  String _songKey(Song song) => '${song.source}:${song.id}';

  // Filters out tracks from the remote liked songs list that were unliked locally within the past 2 hours.
  // Cleans up expired entries from _recentlyUnlikedSongs to prevent memory leaks.
  List<Song> _mergeLikedSongs(List<Song> remoteLiked) {
    bool removedAny = false;
    // Remove entries older than 2 hours (120 minutes)
    _recentlyUnlikedSongs.removeWhere((_, time) {
      final old = DateTime.now().difference(time).inMinutes > 120;
      if (old) removedAny = true;
      return old;
    });
    if (removedAny) unawaited(_saveRecentlyUnliked());

    // Exclude any song that is currently recorded as recently unliked
    return remoteLiked.where((s) => !_recentlyUnlikedSongs.containsKey(s.id)).toList();
  }

  // Completely clears user session credentials, cached profile, and stored library from disk.
  // Resets the provider back to empty guest mode.
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

  // Wraps an asynchronous operation with loading state management (_busy = true/false).
  // Ensures listeners are notified when work begins and safely resets _busy even if an error occurs.
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


  // Sets the active user's authentication cookie, updates authorization flags,
  // and triggers an automatic library sync if requested or overdue.
  Future<void> _setUser(
    String cookie, {
    bool fetchIfAuthorized = false,
    bool forceRefresh = false,
  }) async {
    _cookieString = cookie;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('sapisid_cookie', cookie);

    // If memory library is completely empty, restore the cached version first for instant display.
    if (_library.likedSongs.isEmpty && _library.playlists.isEmpty) {
      _restoreCachedLibrary(prefs);
    }

    _youtubeAuthorized = true;
    _mode = AccountMode.youtube;
    await prefs.setBool(_authorizedKey, true);
    // Refresh the library from YouTube if requested and sync conditions are met.
    if (fetchIfAuthorized && (forceRefresh || await _shouldSync())) {
      await refreshLibrary(force: forceRefresh);
    }
    notifyListeners();
  }

  // Determines whether a cloud library synchronization should be performed.
  // Returns true if the library is empty or if 2+ hours have elapsed since the last sync.
  Future<bool> _shouldSync() async {
    final prefs = await SharedPreferences.getInstance();
    final lastSync = prefs.getInt(_lastSyncKey) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;

    // If the in-memory library is empty, an immediate sync is required.
    if (_library.likedSongs.isEmpty && _library.playlists.isEmpty) return true;

    // Auto-sync every 2 hours (1000ms * 60s * 60m * 2h)
    return (now - lastSync) > 1000 * 60 * 60 * 2;
  }

  // Optimistically renames a playlist in memory so the UI changes instantly
  // before the remote YouTube request finishes.
  void updatePlaylistNameOptimistic(String idOrOldName, String newName) {
    final idx = _library.playlists.indexWhere((p) => p.id == idOrOldName || p.title == idOrOldName);
    if (idx >= 0) {
      final p = _library.playlists[idx];
      final newPlaylists = List<MusicPlaylist>.from(_library.playlists);
      newPlaylists[idx] = MusicPlaylist(
        id: p.id, title: newName, owner: p.owner,
        thumbnailUrl: p.thumbnailUrl, itemCount: p.itemCount, source: p.source
      );
      _library = AccountLibrary(
        likedSongs: _library.likedSongs,
        recentSongs: _library.recentSongs,
        playlists: newPlaylists,
      );
      notifyListeners();
    }
  }

  // Optimistically adds a new playlist to the front of the library list for immediate UI feedback.
  void addPlaylistOptimistic(MusicPlaylist p) {
    final newPlaylists = List<MusicPlaylist>.from(_library.playlists)..insert(0, p);
    _library = AccountLibrary(
      likedSongs: _library.likedSongs,
      recentSongs: _library.recentSongs,
      playlists: newPlaylists,
    );
    notifyListeners();
  }

  // Optimistically removes a playlist from memory and local storage.
  // Adds its ID to _deletedPlaylists so future merges don't accidentally revive it.
  void removePlaylistOptimistic(String id, String title) {
    _deletedPlaylists.add(id);
    _storage.deletePlaylist(title); // Prevent local storage from reviving it
    final newPlaylists = _library.playlists.where((p) => p.id != id).toList();
    _library = AccountLibrary(
      likedSongs: _library.likedSongs,
      recentSongs: _library.recentSongs,
      playlists: newPlaylists,
    );
    notifyListeners();
  }

  // Refreshes the user's music library from YouTube Music and reconciles it with local storage.
  // Can be forced or throttled based on the last sync timestamp. Updates local cache on success.
  Future<void> refreshLibrary({bool force = false}) async {
    final account = _cookieString;
    if (account == null || !_youtubeAuthorized) return;
    if (_syncingLibrary && !force) return;

    // Check whether sync should run or wait based on the 2-hour interval.
    if (!force && !await _shouldSync()) {
      debugPrint('AccountProvider: Sync interval not reached, skipping.');
      return;
    }

    await _runBusy(() async {
      _syncingLibrary = true;
      _errorMessage = null; // Clear previous errors before starting
      try {
        debugPrint('AccountProvider: Starting library refresh...');
        final headers = await getAuthHeaders();
        if (headers != null && headers.isNotEmpty) {
          // Fetch remote library (liked songs, playlists, history) from YouTube.
          final newLib = await _youtubeAccountService.fetchLibrary(headers);

          // If the network response was completely empty, fallback to cached library.
          if (newLib.likedSongs.isEmpty && newLib.playlists.isEmpty) {
            debugPrint('AccountProvider: Fetched library is empty.');
            if (_library.likedSongs.isNotEmpty ||
                _library.playlists.isNotEmpty) {
              _errorMessage = 'Using cached library; refresh returned empty.';
              return;
            }
          }

          // If playlists failed to fetch but liked songs succeeded, preserve existing playlists
          final safePlaylists = newLib.playlists.isEmpty && _library.playlists.isNotEmpty 
              ? _library.playlists 
              : newLib.playlists;
              
          final safeLib = AccountLibrary(
            likedSongs: newLib.likedSongs,
            recentSongs: newLib.recentSongs,
            playlists: safePlaylists,
          );

          // Merge local and remote changes with a safety timeout for heavy operations.
          _library = await _mergeAndPushLocalLibrary(headers, safeLib)
              .timeout(const Duration(seconds: 150));

          // Save the merged library to local storage for offline use.
          await _cacheLibrary();

          // Save current timestamp as last successful sync time.
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

  // Adds a YouTube song to a synced playlist on YouTube Music.
  // Ensures the playlist exists remotely, checks for duplicates, and triggers a background sync.
  Future<void> addSongToSyncedPlaylist(String playlistName, Song song) async {
    if (song.source != 'youtube') return;
    final headers = await getAuthHeaders();
    if (headers == null) return;

    try {
      final playlist = await _ensureYoutubePlaylist(headers, playlistName);
      if (playlist == null) return;

      // Verify the song is not already in the playlist to avoid remote duplicates.
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
        // Refresh library in the background so changes show up in the UI.
        if (added) unawaited(refreshLibrary());
      }
    } catch (e) {
      debugPrint('Synced playlist add failed: $e');
    }
  }

  // Removes a song from a synced playlist on YouTube Music and triggers a background refresh.
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

  // Builds the HTTP Cookie header required for authenticated YouTube Music requests.
  Future<Map<String, String>?> getAuthHeaders() async {
    final cookie = _cookieString;
    if (cookie == null || cookie.isEmpty) return null;
    return {'Cookie': cookie};
  }

  // Fetches personalized YouTube Music home feed sections and recommendation chips.
  // Supports continuous scroll pagination via continuationToken.
  Future<HomeFeedData> fetchHomeFeed({String? continuationToken}) async {
    final headers = await getAuthHeaders();
    if (headers == null) return const HomeFeedData(chips: [], sections: []);
    return await _youtubeAccountService.fetchHomeFeed(headers, params: continuationToken);
  }

}
