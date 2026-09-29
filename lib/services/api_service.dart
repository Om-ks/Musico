import 'dart:async';
import 'dart:convert';

import 'package:dart_ytmusic_api/dart_ytmusic_api.dart' as ytm;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;
import 'package:yt_flutter_musicapi/yt_flutter_musicapi.dart';

import '../models/music_playlist.dart';
import '../models/song.dart';

// Represents a single horizontal shelf or section on the home screen
// (for example: "Trending Hits", "Chill Beats", or "Because You Listened To...").
class MusicRecommendationSection {
  // The header title displayed above the songs or playlists in this section.
  final String title;

  // The list of songs that belong to this recommendation shelf.
  final List<Song> songs;

  // The list of playlists that belong to this recommendation shelf.
  final List<MusicPlaylist> playlists;

  // Combined mixed list containing both songs and playlists for flexible UI rendering.
  final List<dynamic> items;

  // Constructor requiring the section title, songs, and playlists.
  const MusicRecommendationSection({
    required this.title,
    required this.songs,
    required this.playlists,
    this.items = const [],
  });
}

// Represents a category filter pill or chip shown at the top of the home screen
// (for example: "Relax", "Workout", "Party").
class HomeFeedChip {
  // The user-facing label text displayed on the chip.
  final String text;

  // An optional token used to fetch the next page or specific category feed from YouTube Music.
  final String? token;

  // Constructor for creating a filter chip.
  const HomeFeedChip({required this.text, this.token});
}

// Encapsulates all data needed to render the home screen feed,
// including top filter chips and various song/playlist sections.
class HomeFeedData {
  // Quick filter chips shown horizontally across the top of the screen.
  final List<HomeFeedChip> chips;

  // The collection of content shelves/sections loaded for the user's home screen.
  final List<MusicRecommendationSection> sections;

  // Constructor requiring the list of filter chips and recommendation sections.
  const HomeFeedData({
    required this.chips,
    required this.sections,
  });
}

// Main service responsible for interacting with YouTube Music, YouTube Explode,
// and third-party audio stream providers (such as Piped).
// Handles searching songs/playlists, generating recommendations, and resolving playable audio URLs.
class ApiService {
  // Standard network timeout for general HTTP and API requests to prevent requests from hanging forever.
  static const Duration _networkTimeout = Duration(seconds: 12);

  // Maximum time allowed to resolve an audio stream manifest before aborting.
  // Reduced from 35s: getManifest either succeeds in <10s or hangs.
  // 12s gives enough headroom for slow connections without blocking the UI.
  static const Duration _streamResolutionTimeout = Duration(seconds: 12);

  // Maximum time cached audio stream URLs remain valid before requiring fresh resolution.
  // Reduced to 4 hours because YouTube's googlevideo streams expire strictly at the 6-hour mark.
  static const Duration _streamCacheMaxAge = Duration(hours: 4);

  // YouTube Music API client used for searching tracks, playlists, and fetching suggestions.
  static final ytm.YTMusic _ytMusic = ytm.YTMusic();

  // YouTube Explode client used as a fallback for scraping video streams and playlist details.
  static final yt.YoutubeExplode _youtube = yt.YoutubeExplode();

  // Reusable HTTP client for sending network requests (e.g., Piped API calls and reachability checks).
  static final http.Client _http = http.Client();

  // In-memory cache mapping unique song keys (source:id) to their pending or resolved stream URL lists.
  // This prevents multiple simultaneous stream resolution calls for the exact same track.
  static final Map<String, Future<List<String>>> _streamUrlCache = {};

  // Timestamps recording when each audio stream URL was placed into the cache, used for expiration checks.
  static final Map<String, DateTime> _streamUrlCachedAt = {};

  // Piped public instances – tried in order, first success wins.
  // These resolve YouTube stream URLs server-side in ~300-800ms
  // vs youtube_explode_dart which takes 5-15s doing it locally.
  static const List<String> _pipedInstances = [
    'https://pipedapi.kavin.rocks',
    'https://pipedapi.smnz.de',
    'https://pipedapi.lunar.icu',
    'https://pipedapi.in.projectsegfau.lt',
    'https://pipedapi.us.projectsegfau.lt',
  ];

  // Memoized initialization Future to ensure the YouTube Music clients are initialized only once.
  static Future<void>? _ytInitFuture;

  // Searches for songs matching a user query across YouTube Music and YouTube video sources.
  // Results are ranked using a relevance scoring system to place the best matches first.
  static Future<List<Song>> search(String query, {int limit = 25}) async {
    // Remove leading and trailing whitespace from the user search query.
    final cleanQuery = query.trim();
    // Return an empty list immediately if the search query is blank.
    if (cleanQuery.isEmpty) return [];

    // Perform the multi-source YouTube search.
    final youtube = await _ytSearch(cleanQuery, limit: limit);
    // Sort and rank songs according to title/artist match relevance, then limit the result count.
    return _rankSongsForQuery(cleanQuery, youtube).take(limit).toList();
  }

  // Fetches a rotating list of trending songs based on the current hour of the day.
  // Useful for displaying fresh content on the home screen when no search is active.
  static Future<List<Song>> getTrending() async {
    // Rotating set of queries representing different popular genres and moods.
    const queries = [
      'top songs global',
      'trending music',
      'latest hits',
      'bollywood hits',
      'lofi songs',
      'pop hits',
    ];
    // Select one query based on the current hour so content changes throughout the day.
    final query = queries[DateTime.now().hour % queries.length];
    return search(query, limit: 24);
  }

  // Generates personalized recommendation sections (shelves) for the home screen
  // based on the user's recent playback history.
  static Future<HomeFeedData> getRecommendedSections(
    List<Song> history,
  ) async {
    // Extract recommendation search queries derived from artists and tracks in listening history.
    final seeds = _recommendationSeeds(history);

    // Build a Set of already-listened song keys to avoid recommending songs the user just played.
    final listenedKeys = {
      for (final song in history) '${song.source}:${song.id}',
    };

    // For each seed, fetch matching songs and playlists in parallel.
    final sections = await Future.wait(
      seeds.map((seed) async {
        // Fetch up to 12 songs and up to 6 playlists matching the seed query.
        final results = await Future.wait<dynamic>([
          search(seed.query, limit: 12),
          searchPlaylists(seed.query, limit: 6),
        ]);

        // Filter out songs that the user has already listened to recently.
        final outSongs = (results[0] as List<Song>)
            .where(
                (song) => !listenedKeys.contains('${song.source}:${song.id}'))
            .toList();
        final outPlaylists = results[1] as List<MusicPlaylist>;
            
        // Construct the recommendation shelf with songs and playlists.
        return MusicRecommendationSection(
          title: seed.title,
          songs: outSongs,
          playlists: outPlaylists,
          items: [...outSongs, ...outPlaylists],
        );
      }),
    );

    // Filter out any recommendation sections that came back completely empty.
    final filteredSections = sections
        .where((section) =>
            section.songs.isNotEmpty || section.playlists.isNotEmpty)
        .toList();

    return HomeFeedData(chips: [], sections: filteredSections);
  }

  // Provides search query autocomplete suggestions as the user types in the search bar.
  static Future<List<String>> getSearchSuggestions(String query) async {
    final cleanQuery = query.trim();
    // Do not request suggestions until the user has typed at least 2 characters.
    if (cleanQuery.length < 2) return [];

    final suggestions = <String>{};
    try {
      // Ensure API client is initialized before querying.
      await _ensureYtInitialized();
      // Fetch suggestions from YouTube Music with a fast 5-second timeout.
      final ytSuggestions = await _ytMusic
          .getSearchSuggestions(cleanQuery)
          .timeout(const Duration(seconds: 5));
      suggestions.addAll(
        ytSuggestions.map(_cleanText).where((item) => item.isNotEmpty),
      );
    } catch (e) {
      // Log failure and gracefully return any suggestions collected so far.
      debugPrint('Error getting recommendations: $e');
    }

    // Limit to the top 10 suggestions.
    return suggestions.take(10).toList();
  }

  // Direct search against YouTube Music without secondary ranking.
  // Useful for targeted searches or quick result queries.
  static Future<List<Song>> searchYoutubeMusic(
    String query, {
    int limit = 20,
  }) {
    final cleanQuery = query.trim();
    if (cleanQuery.isEmpty) return Future.value([]);
    return _ytSearch(cleanQuery, limit: limit);
  }

  // Searches YouTube Music specifically for playlists matching the search term.
  static Future<List<MusicPlaylist>> searchPlaylists(
    String query, {
    int limit = 8,
  }) async {
    final cleanQuery = query.trim();
    if (cleanQuery.isEmpty) return [];

    try {
      await _ensureYtInitialized();
      // Safely perform playlist search with a network timeout wrapper.
      final playlists = await _safeYtList<ytm.PlaylistDetailed>(
        'Playlist search',
        () => _ytMusic.searchPlaylists(cleanQuery),
      );

      // Convert YouTube Music playlist objects into our app's MusicPlaylist model.
      return playlists
          .where((playlist) => playlist.playlistId.isNotEmpty)
          .map(_playlistFromYt)
          .take(limit)
          .toList();
    } catch (e) {
      debugPrint('Playlist search failed for "$query": $e');
      return [];
    }
  }

  // Convenience helper that extracts the ID and title from a MusicPlaylist object
  // and delegates to getPlaylistSongsById.
  static Future<List<Song>> getPlaylistSongs(
    MusicPlaylist playlist, {
    int limit = 150,
  }) {
    return getPlaylistSongsById(
      playlist.id,
      playlistTitle: playlist.title,
      limit: limit,
    );
  }

  // Fetches all playable songs inside a specific playlist ID.
  // First attempts retrieval via YouTube Music API with multiple ID formats (e.g., with/without 'VL' prefix).
  // If that fails or returns no tracks, falls back to the YouTube Explode scraper.
  static Future<List<Song>> getPlaylistSongsById(
    String playlistId, {
    String playlistTitle = 'Playlist',
    int limit = 150,
  }) async {
    final cleanId = playlistId.trim();
    if (cleanId.isEmpty) return [];

    await _ensureYtInitialized();
    // YouTube playlist IDs may appear with or without 'VL' prefix; test both candidates.
    for (final candidateId in _playlistIdCandidates(cleanId)) {
      try {
        final videos = await _ytMusic
            .getPlaylistVideos(candidateId)
            .timeout(const Duration(seconds: 18));

        debugPrint(
            'Playlist $playlistTitle ($candidateId): YTMusic returned ${videos.length} videos');

        if (videos.isNotEmpty) {
          // Map raw video items to Song objects.
          final mapped = videos
              .map((video) => _songFromYtPlaylistVideo(video, playlistTitle))
              .toList();
          final filtered = mapped.where((song) => song.id.isNotEmpty).toList();
          debugPrint(
              'Playlist $playlistTitle: Mapped to ${mapped.length} songs, ${filtered.length} with valid IDs');

          // Keep only songs that pass our music/audio heuristics (filtering out junk/vlogs).
          final musicFiltered = filtered.where(_isLikelyMusic).toList();
          debugPrint(
              'Playlist $playlistTitle: After music filter, ${musicFiltered.length} songs remain');

          final songs = musicFiltered.take(limit).toList();

          if (songs.isNotEmpty) {
            // Pre-resolve stream URLs for the first few songs so playback starts instantly.
            _warmStreamCache(songs.take(4));
            return songs;
          }
        }
      } catch (e) {
        debugPrint('YTMusic playlist videos failed for $candidateId: $e');
      }
    }

    // Fallback: If YouTube Music API returned nothing, scrape using YouTube Explode.
    try {
      // Normal YouTube playlist IDs must not have the 'VL' prefix.
      final youtubePlaylistId =
          cleanId.startsWith('VL') ? cleanId.substring(2) : cleanId;
      final videos = await _youtube.playlists
          .getVideos(youtubePlaylistId)
          .take(limit)
          .timeout(const Duration(seconds: 18))
          .toList();

      debugPrint(
          'Playlist $playlistTitle ($youtubePlaylistId): YouTube fallback returned ${videos.length} videos');

      final songs = videos
          .map((video) {
            return Song(
              id: video.id.value,
              title: _cleanText(video.title, fallback: 'Unknown Track'),
              artist: _cleanText(video.author, fallback: 'Unknown Artist'),
              album: playlistTitle,
              thumbnailUrl: video.thumbnails.highResUrl,
              duration: video.duration?.inSeconds ?? 0,
              source: 'youtube',
            );
          })
          .where(_isLikelyMusic)
          .toList();

      debugPrint(
          'Playlist $playlistTitle: After music filter, ${songs.length} songs remain');

      // Pre-warm the cache for fast playback start.
      _warmStreamCache(songs.take(4));
      return songs;
    } catch (e) {
      debugPrint('YouTube playlist fallback failed for $cleanId: $e');
      return [];
    }
  }

  // Generates different playlist ID variations (raw, with 'VL' prefix, without 'VL' prefix)
  // because YouTube Music and YouTube endpoints expect different formatting.
  static List<String> _playlistIdCandidates(String playlistId) {
    final clean = playlistId.trim();
    if (clean.isEmpty) return const [];
    final withoutVl = clean.startsWith('VL') ? clean.substring(2) : clean;
    final withVl = clean.startsWith('VL') ? clean : 'VL$clean';
    return <String>{clean, withVl, withoutVl}
        .where((id) => id.isNotEmpty)
        .toList();
  }

  // Convenience method that returns the primary playable audio URL for a song.
  // Returns null if no playable audio stream could be discovered.
  static Future<String?> getStreamUrl(String id, String source) async {
    final urls = await getStreamUrls(id, source);
    return urls.isEmpty ? null : urls.first;
  }

  // Removes a song's audio stream URLs from the in-memory cache.
  // Typically called if playback failed due to an expired or 403 stream link.
  static void clearStreamCache(String id, String source) {
    final cacheKey = '$source:${id.trim()}';
    _streamUrlCache.remove(cacheKey);
    _streamUrlCachedAt.remove(cacheKey);
  }

  // Resolves a list of playable direct audio stream URLs for a song.
  // Utilizes an in-memory cache with an 8-hour expiration to speed up repeated playback
  // and prevent duplicate network traffic.
  static Future<List<String>> getStreamUrls(String id, String source,
      {bool forceRefresh = false}) async {
    final cleanId = id.trim();
    if (cleanId.isEmpty) return [];

    final cacheKey = '$source:$cleanId';
    final cachedAt = _streamUrlCachedAt[cacheKey];
    final cachedFuture = _streamUrlCache[cacheKey];

    // Return the cached Future if it exists, is still valid, and force refresh wasn't requested.
    if (!forceRefresh &&
        cachedFuture != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < _streamCacheMaxAge) {
      return cachedFuture;
    }

    // If forcing a refresh, evict old entries from cache first.
    if (forceRefresh) {
      _streamUrlCache.remove(cacheKey);
      _streamUrlCachedAt.remove(cacheKey);
    }

    // Resolve stream URLs via YouTube backend / Piped / YouTube Explode.
    final future = _getYoutubeStreamUrls(cleanId).then((urls) {
      // If no valid URLs were found, do not leave an empty list cached.
      if (urls.isEmpty) {
        _streamUrlCache.remove(cacheKey);
        _streamUrlCachedAt.remove(cacheKey);
      }
      return urls;
    }).catchError((Object error) {
      // Clean up cache entry on error so subsequent attempts can retry.
      _streamUrlCache.remove(cacheKey);
      _streamUrlCachedAt.remove(cacheKey);
      debugPrint('Stream URL resolution failed for $cleanId: $error');
      return <String>[];
    });

    // Store the pending or completed Future into the cache.
    _streamUrlCache[cacheKey] = future;
    _streamUrlCachedAt[cacheKey] = DateTime.now();
    return future;
  }

  // Internal helper that queries multiple YouTube endpoints in parallel:
  // - YTMusic song search
  // - YTMusic video search
  // - YTMusic mixed search
  // - YouTube web video search
  // Deduplicates results and filters out non-music videos.
  static Future<List<Song>> _ytSearch(String query,
      {required int limit}) async {
    try {
      await _ensureYtInitialized();

      // Run multiple search queries concurrently to aggregate comprehensive results.
      final batches = await Future.wait<List<Song>>([
        _safeYtList<ytm.SongDetailed>(
          'YTMusic song search',
          () => _ytMusic.searchSongs(query),
        ).then((results) => results.map(_songFromYtMusic).toList()),
        _safeYtList<ytm.VideoDetailed>(
          'YTMusic video search',
          () => _ytMusic.searchVideos(query),
        ).then((results) => results.map(_songFromYtVideo).toList()),
        _safeYtList<ytm.SearchResult>(
          'YTMusic mixed search',
          () => _ytMusic.search(query),
        ).then((results) =>
            results.map(_songFromYtSearchResult).whereType<Song>().toList()),
        _youtubeVideoSearch(query, limit: limit < 25 ? limit : 25),
      ]);
      final songs = _uniqueSongs(batches.expand((batch) => batch))
          .where((song) => song.id.isNotEmpty)
          .where(_isLikelyMusic)
          .toList();

      debugPrint('YTMusic search "$query" returned ${songs.length} songs.');
      // Pre-warm the stream cache for top items to ensure fast click-to-play latency.
      _warmStreamCache(songs.take(6));
      return songs;
    } catch (e) {
      debugPrint('YTMusic search failed for "$query": $e');
      return [];
    }
  }

  // Heuristic filter to determine if a video result is genuinely musical content
  // rather than a podcast, lecture, tutorial, or vlog.
  static bool _isLikelyMusic(Song song) {
    final title = song.title.toLowerCase();

    // 1. CLEAR MUSIC SIGNALS (Allow immediately if any musical keyword matches)
    final musicMarkers = [
      'song',
      'music',
      'official audio',
      'official video',
      'remix',
      'lyrics',
      'ost',
      'live',
      'concert',
      'performance',
      'audio',
      'visualizer',
      'mv',
      'lofi',
      'chill',
      'beat',
      'instrumental',
      'soundtrack',
      'karaoke',
      'cover',
      'vocal',
      'acoustic',
      'unplugged',
      'mix'
    ];
    if (musicMarkers.any((m) => title.contains(m))) return true;

    // 2. CLEAR NON-MUSIC SIGNALS (Block only the most obvious non-music content)
    final blacklist = [
      'lecture',
      'tutorial',
      'vlog',
      'unboxing',
      'course',
      'webinar',
      'presentation',
      'how to',
      'daily vlog',
      'funny moments',
      'prank',
      'challenge',
      'shopping',
      'haul',
      'makeup',
      'asmr',
      'gaming',
      'walkthrough',
      'gameplay',
      'highlights',
      'morning routine',
      'night routine'
    ];

    if (blacklist.any((kw) => title.contains(kw))) return false;

    // 3. Duration check for ambiguous items (less than 20 seconds is likely not a full song)
    if (song.duration > 0 && song.duration < 20) return false;

    return true;
  }

  // Wraps an asynchronous YouTube API request with timeout handling and error catching,
  // returning an empty list instead of crashing on network failure.
  static Future<List<T>> _safeYtList<T>(
    String label,
    Future<List<T>> Function() request,
  ) async {
    try {
      return await request().timeout(_networkTimeout);
    } catch (e) {
      debugPrint('$label failed: $e');
      return [];
    }
  }

  // Converts a detailed YouTube Music song object into our app's Song model.
  static Song _songFromYtMusic(ytm.SongDetailed song) {
    // Pick the highest resolution thumbnail (usually the last item in the list).
    final thumb = song.thumbnails.isNotEmpty
        ? song.thumbnails.last.url
        : Song.fallbackArtUrl;

    return Song(
      id: song.videoId,
      title: _cleanText(song.name, fallback: 'Unknown Track'),
      artist: _cleanText(song.artist.name, fallback: 'Unknown Artist'),
      album: _cleanText(song.album?.name, fallback: 'Single'),
      thumbnailUrl: thumb,
      duration: song.duration ?? 0,
      source: 'youtube',
    );
  }

  // Converts a detailed YouTube Music video object into our app's Song model.
  static Song _songFromYtVideo(ytm.VideoDetailed video) {
    final thumb = video.thumbnails.isNotEmpty
        ? video.thumbnails.last.url
        : Song.fallbackArtUrl;

    return Song(
      id: video.videoId,
      title: _cleanText(video.name, fallback: 'Unknown Track'),
      artist: _cleanText(video.artist.name, fallback: 'Unknown Artist'),
      album: 'Music Video',
      thumbnailUrl: thumb,
      duration: video.duration ?? 0,
      source: 'youtube',
    );
  }

  // Polymorphic mapper that examines YouTube Music search result types
  // and routes them to the appropriate song converter.
  static Song? _songFromYtSearchResult(ytm.SearchResult result) {
    if (result is ytm.SongDetailedSearchResult) {
      return _songFromYtMusic(result.songDetailed);
    }
    if (result is ytm.VideoDetailedSearchResult) {
      return _songFromYtVideo(result.videoDetailed);
    }
    if (result is ytm.SongDetailed) return _songFromYtMusic(result);
    if (result is ytm.VideoDetailed) return _songFromYtVideo(result);
    return null;
  }

  // Converts a video item found within a YouTube Music playlist into our app's Song model.
  static Song _songFromYtPlaylistVideo(
    ytm.VideoDetailed video,
    String playlistTitle,
  ) {
    final thumb = video.thumbnails.isNotEmpty
        ? video.thumbnails.last.url
        : Song.fallbackArtUrl;

    return Song(
      id: video.videoId,
      title: _cleanText(video.name, fallback: 'Unknown Track'),
      artist: _cleanText(video.artist.name, fallback: 'Unknown Artist'),
      album: playlistTitle,
      thumbnailUrl: thumb,
      duration: video.duration ?? 0,
      source: 'youtube',
    );
  }

  // Searches YouTube web videos using YouTube Explode as an additional music source.
  // Filters out live streams and videos without a defined duration.
  static Future<List<Song>> _youtubeVideoSearch(
    String query, {
    required int limit,
  }) async {
    try {
      final results =
          await _youtube.search.search('$query music').timeout(_networkTimeout);

      return results
          .where((video) => !video.isLive && video.duration != null)
          .map(_songFromYoutubeVideo)
          .where((song) => song.id.isNotEmpty)
          .take(limit)
          .toList();
    } catch (e) {
      debugPrint('YouTube web video search failed for "$query": $e');
      return [];
    }
  }

  // Converts a YouTube Explode Video object into our app's Song model.
  // Extracts music metadata (artist, album, track title) if embedded in the YouTube video description.
  static Song _songFromYoutubeVideo(yt.Video video) {
    var title = _cleanText(video.title, fallback: 'Unknown Track');
    var artist = _cleanText(video.author, fallback: 'Unknown Artist');
    var album = 'Online Video';
    var thumbnailUrl = video.thumbnails.highResUrl;

    // Use official music metadata when YouTube identifies the track in its audio fingerprinting.
    if (video.musicData.isNotEmpty) {
      final music = video.musicData.first;
      title = _cleanText(music.song, fallback: title);
      artist = _cleanText(music.artist, fallback: artist);
      album = _cleanText(music.album, fallback: album);
      thumbnailUrl = music.image?.toString() ?? thumbnailUrl;
    }

    return Song(
      id: video.id.value,
      title: title,
      artist: artist,
      album: album,
      thumbnailUrl: thumbnailUrl,
      duration: video.duration?.inSeconds ?? 0,
      source: 'youtube',
    );
  }

  // Converts a detailed YouTube Music playlist object into our app's MusicPlaylist model.
  static MusicPlaylist _playlistFromYt(ytm.PlaylistDetailed playlist) {
    final thumb = playlist.thumbnails.isNotEmpty
        ? playlist.thumbnails.last.url
        : Song.fallbackArtUrl;

    return MusicPlaylist(
      id: playlist.playlistId,
      title: _cleanText(playlist.name, fallback: 'Playlist'),
      owner: _cleanText(playlist.artist.name, fallback: 'Music'),
      thumbnailUrl: thumb,
      itemCount: 0,
      source: 'youtube',
    );
  }

  // Multi-tiered resolver that attempts to extract direct audio playback links for a YouTube video ID.
  // Tier 1: yt_flutter_musicapi (fast unthrottled endpoint).
  // Tier 2: Public Piped API instances (~300-800ms server-side resolution).
  // Tier 3: youtube_explode_dart client-side cipher resolution.
  static Future<List<String>> _getYoutubeStreamUrls(String videoId) async {
    // Special handling for Flutter Web: browser CORS restrictions require using audio proxy mirrors.
    if (kIsWeb) {
      debugPrint('Web mode: using CORS audio proxy for $videoId');
      return [
        'https://inv.tux.pizza/latest_version?id=$videoId&itag=140',
        'https://invidious.nerdvpn.de/latest_version?id=$videoId&itag=140',
        'https://vid.puffyan.us/latest_version?id=$videoId&itag=140',
      ];
    }
    // ── 1. Try yt_flutter_musicapi (Unthrottled Python backend) ──────────────
    try {
      await _ensureYtInitialized();
      final response = await YtFlutterMusicapi().getAudioUrlFlexible(videoId: videoId);
      if (response.success && response.data != null && response.data!.audioUrl != null && response.data!.audioUrl!.isNotEmpty) {
        debugPrint('yt_flutter_musicapi: resolved stream for $videoId');
        return [response.data!.audioUrl!];
      }
    } catch (e) {
      debugPrint('yt_flutter_musicapi failed for $videoId: $e');
    }

    // ── 2. Try Piped API fallback ────────────────────────────────────────────
    // Piped resolves stream URLs server-side (~300-800ms).
    try {
      final pipedUrls = await _getPipedStreamUrls(videoId);
      if (pipedUrls.isNotEmpty) {
        debugPrint('Piped: resolved ${pipedUrls.length} streams for $videoId');
        return pipedUrls;
      }
    } catch (e) {
      debugPrint('Piped failed for $videoId: $e');
    }

    // ── 3. Fallback: youtube_explode_dart (Throttled but works) ──────────────
    debugPrint('Falling back to youtube_explode for $videoId');
    try {
      final manifest = await _youtube.videos.streams
          .getManifest(videoId)
          .timeout(_streamResolutionTimeout);

      final urls = <String>[];

      // Get all audio-only streams
      final audioOnly = manifest.audioOnly.toList();
      if (audioOnly.isNotEmpty) {
        // Sort: m4a/aac first, then by bitrate (prefer ~128kbps)
        audioOnly.sort((a, b) {
          final aFriendly = _isAndroidFriendlyAudio(a);
          final bFriendly = _isAndroidFriendlyAudio(b);
          if (aFriendly && !bFriendly) return -1;
          if (!aFriendly && bFriendly) return 1;

          final aBitrate = a.bitrate.bitsPerSecond;
          final bBitrate = b.bitrate.bitsPerSecond;

          // Target ~128kbps for best trade-off between audio fidelity and buffering speed.
          final aDiff = (aBitrate - 128000).abs();
          final bDiff = (bBitrate - 128000).abs();
          return aDiff.compareTo(bDiff);
        });

        for (final stream in audioOnly) {
          final url = stream.url.toString();
          if (url.isNotEmpty && !urls.contains(url)) urls.add(url);
        }
      }

      // Fallback to muxed streams if no audio-only or they failed
      final muxed = manifest.muxed.toList()
        ..sort((a, b) => a.bitrate.compareTo(b.bitrate));
      for (final stream in muxed) {
        final url = stream.url.toString();
        if (url.isNotEmpty && !urls.contains(url)) urls.add(url);
      }

      return urls;
    } catch (e) {
      debugPrint('YouTube stream resolution failed for $videoId: $e');
      return [];
    }
  }

  // Queries multiple public Piped instances simultaneously and returns audio streams
  // from the fastest responding server that succeeds.
  static Future<List<String>> _getPipedStreamUrls(String videoId) async {
    final completer = Completer<List<String>>();
    var errors = 0;

    for (final instance in _pipedInstances) {
      // Fire HTTP requests to all instances in parallel with a strict 3-second timeout.
      _http.get(
        Uri.parse('$instance/streams/$videoId'),
        headers: {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 3)).then((response) {
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          final audioStreams = data['audioStreams'] as List<dynamic>?;
          if (audioStreams != null && audioStreams.isNotEmpty) {
            final streams = audioStreams
                .whereType<Map<String, dynamic>>()
                .where((s) {
                  final url = s['url'] as String?;
                  return url != null && url.isNotEmpty;
                })
                .toList();

            if (streams.isNotEmpty) {
              // Prioritize AAC / M4A containers and target ~128kbps bitrate.
              streams.sort((a, b) {
                final aMime = ((a['mimeType'] ?? a['type']) as String? ?? '').toLowerCase();
                final bMime = ((b['mimeType'] ?? b['type']) as String? ?? '').toLowerCase();
                final aFriendly = aMime.contains('mp4') || aMime.contains('m4a') || aMime.contains('aac');
                final bFriendly = bMime.contains('mp4') || bMime.contains('m4a') || bMime.contains('aac');
                if (aFriendly && !bFriendly) return -1;
                if (!aFriendly && bFriendly) return 1;

                final aBitrate = (a['bitrate'] as num?)?.toInt() ?? 0;
                final bBitrate = (b['bitrate'] as num?)?.toInt() ?? 0;
                final aDiff = (aBitrate - 128000).abs();
                final bDiff = (bBitrate - 128000).abs();
                return aDiff.compareTo(bDiff);
              });
              
              if (!completer.isCompleted) {
                completer.complete(streams.map((s) => s['url'] as String).toList());
              }
              return;
            }
          }
        }
        
        errors++;
        // If every single instance failed, complete with an error so fallback triggers.
        if (errors == _pipedInstances.length && !completer.isCompleted) {
          completer.completeError('All piped instances failed');
        }
      }).catchError((e) {
        errors++;
        if (errors == _pipedInstances.length && !completer.isCompleted) {
          completer.completeError('All piped instances failed');
        }
      });
    }

    try {
      return await completer.future;
    } catch (e) {
      return [];
    }
  }

  // Checks whether the audio stream uses formats that native Android ExoPlayer decodes cleanly without issues.
  static bool _isAndroidFriendlyAudio(yt.AudioOnlyStreamInfo stream) {
    final container = stream.container.name.toLowerCase();
    final codec = stream.audioCodec.toLowerCase();
    return container == 'mp4' ||
        container == 'm4a' ||
        codec.contains('mp4a') ||
        codec.contains('aac');
  }

  // Sends an HTTP HEAD request to check whether an audio stream URL responds and is reachable.
  static Future<bool> isDirectAudioReachable(String url) async {
    try {
      final response = await _http.head(Uri.parse(url)).timeout(
            const Duration(seconds: 6),
          );
      return response.statusCode >= 200 && response.statusCode < 400;
    } catch (_) {
      return true;
    }
  }

  // Custom HTTP headers required by certain audio stream hosts (null if standard playback).
  static Map<String, String>? streamHeaders(String source, String id) {
    return null;
  }

  // Removes duplicate songs from a collection by checking either their ID or normalized title + artist.
  static List<Song> _uniqueSongs(Iterable<Song> songs) {
    final seen = <String>{};
    final unique = <Song>[];

    for (final song in songs) {
      // Build a composite key for songs lacking an ID, or use the source and ID.
      final key = song.id.isEmpty
          ? '${song.source}:${_normaliseForMatch(song.title)}:${_normaliseForMatch(song.artist)}'
          : '${song.source}:${song.id}';
      if (seen.add(key)) {
        unique.add(song);
      }
    }

    return unique;
  }

  // Sorts search results so the most relevant tracks appear at the top.
  // Uses _songSearchScore and breaks ties using track duration.
  static List<Song> _rankSongsForQuery(String query, Iterable<Song> songs) {
    final ranked = _uniqueSongs(songs).toList();
    ranked.sort((a, b) {
      final scoreB = _songSearchScore(query, b);
      final scoreA = _songSearchScore(query, a);
      final scoreCompare = scoreB.compareTo(scoreA);
      if (scoreCompare != 0) return scoreCompare;
      return b.duration.compareTo(a.duration);
    });
    return ranked;
  }

  // Calculates a numerical relevance score between a search query and a song.
  // Higher scores indicate better matches.
  static double _songSearchScore(String query, Song song) {
    final q = _normaliseWords(query);
    final title = _normaliseWords(song.title);
    final artist = _normaliseWords(song.artist);
    final album = _normaliseWords(song.album);
    final tokens = q.split(' ').where((token) => token.length > 1).toList();

    var score = 0.0;
    final combined1 = '$title $artist'.trim();
    final combined2 = '$artist $title'.trim();

    // Exact full title match awards the highest point boost.
    if (title == q || combined1 == q || combined2 == q) score += 150;
    // Title starting with query is a strong signal.
    if (title.startsWith(q) || combined1.startsWith(q) || combined2.startsWith(q)) score += 80;
    // Title contains query.
    if (title.contains(q) || combined1.contains(q) || combined2.contains(q)) score += 50;
    // Artist matches query.
    if (artist.contains(q)) score += 20;
    // Album matches query.
    if (album.contains(q)) score += 10;

    // Word token level scoring.
    for (final token in tokens) {
      if (title.split(' ').contains(token)) score += 7;
      if (title.contains(token)) score += 4;
      if (artist.contains(token)) score += 2.5;
      if (album.contains(token)) score += 1.5;
    }

    // Penalize unofficial variations (e.g., covers/remixes) unless the user explicitly searched for them.
    final queryAsksVariant = q.contains('instrumental') ||
        q.contains('cover') ||
        q.contains('remix') ||
        q.contains('karaoke') ||
        q.contains('sped up') ||
        q.contains('slowed');
    final titleIsVariant = title.contains('instrumental') ||
        title.contains('cover') ||
        title.contains('karaoke') ||
        title.contains('remix') ||
        title.contains('sped up') ||
        title.contains('slowed');
    if (titleIsVariant && !queryAsksVariant) score -= 12;

    // Prefer official audio releases with proper album titles over generic videos.
    if (song.album != 'Music Video' && song.album != 'Online Video') {
      score += 80;
    } else {
      score -= 40;
    }
    // Boost tracks with typical radio song lengths (between 1 and 12 minutes).
    if (song.duration > 60 && song.duration < 720) score += 5;
    if (song.source == 'youtube') score += 2;
    return score;
  }

  // Analyzes the user's listening history to generate seed topics for recommendations.
  // If the history is empty, defaults to popular generic music categories.
  static List<_RecommendationSeed> _recommendationSeeds(List<Song> history) {
    // Fallback seeds for brand-new users with no listening history.
    if (history.isEmpty) {
      final fallbackSeeds = [
        const _RecommendationSeed('Trending Global Hits', 'global top hits'),
        const _RecommendationSeed('Popular Music', 'trending music hits'),
        const _RecommendationSeed('Lofi & Chill', 'lofi chill beats'),
        const _RecommendationSeed('Bollywood Hits', 'bollywood top songs'),
        const _RecommendationSeed('Pop & Dance', 'pop dance hits'),
        const _RecommendationSeed('Hip Hop Essentials', 'hip hop top hits'),
        const _RecommendationSeed('Workout Mix', 'workout pump music'),
        const _RecommendationSeed('Acoustic Relax', 'acoustic calm songs'),
        const _RecommendationSeed('Viral TikTok Songs', 'viral trending songs'),
        const _RecommendationSeed('R&B Grooves', 'r&b soul hits'),
      ];
      fallbackSeeds.shuffle();
      return fallbackSeeds.take(5).toList();
    }

    final uniqueHistory = _uniqueSongs(history).take(120).toList();
    final profileText = uniqueHistory
        .map((song) => '${song.title} ${song.artist} ${song.album}')
        .join(' ')
        .toLowerCase();

    // Frequency maps to identify user's favorite artists, albums, and tracks.
    final artistCounts = <String, int>{};
    final albumCounts = <String, int>{};
    final titleCounts = <String, int>{};

    for (final song in history.take(220)) {
      final artist = song.artist.trim();
      if (artist.isNotEmpty && artist != 'Unknown Artist') {
        artistCounts[artist] = (artistCounts[artist] ?? 0) + 1;
      }

      final album = song.album.trim();
      if (album.isNotEmpty && album != 'Single' && album != 'Online Video') {
        albumCounts[album] = (albumCounts[album] ?? 0) + 1;
      }

      final title = song.title.trim();
      if (title.isNotEmpty && title != 'Unknown Track') {
        titleCounts[title] = (titleCounts[title] ?? 0) + 1;
      }
    }

    // Extract the top preferences.
    final topArtists = _topKeys(artistCounts, 5);
    final topAlbums = _topKeys(albumCounts, 3);
    final topTitles = _topKeys(titleCounts, 5);
    final topTerms = _topProfileTerms(uniqueHistory, 5);

    final seeds = <_RecommendationSeed>[];

    // Create tailored recommendation seeds based on top artists.
    if (topArtists.isNotEmpty) {
      seeds.add(
        _RecommendationSeed(
          'Your Music Mix',
          '${topArtists.take(4).join(' ')} ${topTerms.take(2).join(' ')} songs',
        ),
      );
      seeds.add(
        _RecommendationSeed(
          'Artist Radio',
          '${topArtists.take(3).join(' ')} radio mix',
        ),
      );
    }

    // Create tailored seeds based on favorite song titles.
    if (topTitles.isNotEmpty) {
      seeds.add(
        _RecommendationSeed(
          'Because You Listen',
          '${topTitles.take(4).join(' ')} similar songs',
        ),
      );
    }

    // Create tailored seeds based on recurring albums or keywords.
    if (topAlbums.isNotEmpty || topTerms.isNotEmpty) {
      seeds.add(
        _RecommendationSeed(
          'More For Your Taste',
          '${[...topAlbums.take(2), ...topTerms.take(4)].join(' ')} playlist',
        ),
      );
    }

    // Genre/mood detection based on words occurring in listening history.
    if (profileText.contains('ambient') ||
        profileText.contains('lofi') ||
        profileText.contains('sleep') ||
        profileText.contains('chill')) {
      seeds.add(
        const _RecommendationSeed(
          'Chill Picks',
          'ambient lofi chill songs playlist',
        ),
      );
    }
    if (profileText.contains('90s') ||
        profileText.contains('1990') ||
        profileText.contains('classic')) {
      seeds.add(
        const _RecommendationSeed('Classic Picks', '90s classic hits songs'),
      );
    }
    if (profileText.contains('game') ||
        profileText.contains('ost') ||
        profileText.contains('soundtrack')) {
      seeds.add(
        const _RecommendationSeed(
          'Soundtrack Mode',
          'game ost cinematic soundtrack playlist',
        ),
      );
    }

    // Deduplicate seeds by title and sanitize whitespace.
    final deduped = <String, _RecommendationSeed>{};
    for (final seed in seeds) {
      final query = seed.query.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (query.isEmpty) continue;
      deduped.putIfAbsent(
          seed.title, () => _RecommendationSeed(seed.title, query));
    }
    return deduped.values.take(4).toList();
  }

  // Returns the top N keys from a frequency map, sorted in descending order of occurrence.
  static List<String> _topKeys(Map<String, int> counts, int limit) {
    final entries = counts.entries.toList()
      ..sort((a, b) {
        final countCompare = b.value.compareTo(a.value);
        if (countCompare != 0) return countCompare;
        return a.key.compareTo(b.key);
      });
    return entries.take(limit).map((entry) => entry.key).toList();
  }

  // Extracts frequent descriptive keywords from track and album titles, skipping common stop words.
  static List<String> _topProfileTerms(List<Song> history, int limit) {
    const ignored = {
      'the',
      'and',
      'with',
      'feat',
      'ft',
      'official',
      'video',
      'audio',
      'lyrics',
      'song',
      'songs',
      'music',
      'unknown',
      'track',
      'single',
      'remix',
    };
    final counts = <String, int>{};
    for (final song in history) {
      final words = _normaliseWords('${song.title} ${song.album}').split(' ');
      for (final word in words) {
        if (word.length < 3 || ignored.contains(word)) continue;
        counts[word] = (counts[word] ?? 0) + 1;
      }
    }
    return _topKeys(counts, limit);
  }

  // Asynchronously pre-fetches audio stream links for upcoming songs into the cache.
  static void _warmStreamCache(Iterable<Song> songs) {
    // Warm up only 3 songs. Doing too many concurrently causes youtube_explode_dart
    // to spawn massive JS decryption threads, locking up the CPU for 30s+.
    for (final song in songs.take(3)) {
      unawaited(getStreamUrls(song.id, song.source));
    }
  }

  // Ensures YouTube Music and underlying API clients are initialized with appropriate locale/region.
  static Future<void> _ensureYtInitialized() {
    return _ytInitFuture ??= () async {
      try {
        await _ytMusic.initialize(gl: 'US', hl: 'en');
      } catch (error) {
        debugPrint('YTMusic initialization failed: $error');
      }
      try {
        if (!YtFlutterMusicapi().isInitialized) {
           await YtFlutterMusicapi().initialize(country: 'US');
        }
      } catch (error) {
        debugPrint('YtFlutterMusicapi initialization failed: $error');
      }
    }();
  }

  // Cleans HTML entities and escaped characters from strings returned by external APIs.
  static String _cleanText(dynamic value, {String fallback = ''}) {
    if (value == null) return fallback;
    final text = value.toString().trim();
    if (text.isEmpty || text == 'null') return fallback;
    return text
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#039;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>');
  }

  // Normalizes a string for exact identity matching by stripping all non-alphanumeric characters.
  static String _normaliseForMatch(String value) {
    return value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
  }

  // Normalizes a string into lowercased words separated by a single space for fuzzy matching and tokenization.
  static String _normaliseWords(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
  }
}

// Internal data holder representing a topic seed used to query recommended music for the user.
class _RecommendationSeed {
  // Title for the shelf shown to the user (e.g. "Because You Listen").
  final String title;

  // The actual search query sent to the API to find tracks for this shelf.
  final String query;

  // Const constructor for creating an immutable seed pair.
  const _RecommendationSeed(this.title, this.query);
}
