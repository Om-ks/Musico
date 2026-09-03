import 'dart:async';
import 'dart:convert';

import 'package:dart_ytmusic_api/dart_ytmusic_api.dart' as ytm;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;
import 'package:yt_flutter_musicapi/yt_flutter_musicapi.dart';

import '../models/music_playlist.dart';
import '../models/song.dart';

class MusicRecommendationSection {
  final String title;
  final List<Song> songs;
  final List<MusicPlaylist> playlists;
  final List<dynamic> items;

  const MusicRecommendationSection({
    required this.title,
    required this.songs,
    required this.playlists,
    this.items = const [],
  });
}

class HomeFeedChip {
  final String text;
  final String? token;
  const HomeFeedChip({required this.text, this.token});
}

class HomeFeedData {
  final List<HomeFeedChip> chips;
  final List<MusicRecommendationSection> sections;

  const HomeFeedData({
    required this.chips,
    required this.sections,
  });
}

class ApiService {
  static const Duration _networkTimeout = Duration(seconds: 12);
  // Reduced from 35s: getManifest either succeeds in <10s or hangs.
  // 12s gives enough headroom for slow connections without blocking the UI.
  static const Duration _streamResolutionTimeout = Duration(seconds: 12);
  static const Duration _streamCacheMaxAge = Duration(hours: 8);

  static final ytm.YTMusic _ytMusic = ytm.YTMusic();
  static final yt.YoutubeExplode _youtube = yt.YoutubeExplode();
  static final http.Client _http = http.Client();
  static final Map<String, Future<List<String>>> _streamUrlCache = {};
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

  static Future<void>? _ytInitFuture;

  static Future<List<Song>> search(String query, {int limit = 25}) async {
    final cleanQuery = query.trim();
    if (cleanQuery.isEmpty) return [];

    final youtube = await _ytSearch(cleanQuery, limit: limit);
    return _rankSongsForQuery(cleanQuery, youtube).take(limit).toList();
  }

  static Future<List<Song>> getTrending() async {
    const queries = [
      'top songs global',
      'trending music',
      'latest hits',
      'bollywood hits',
      'lofi songs',
      'pop hits',
    ];
    final query = queries[DateTime.now().hour % queries.length];
    return search(query, limit: 24);
  }

  static Future<HomeFeedData> getRecommendedSections(
    List<Song> history,
  ) async {
    final seeds = _recommendationSeeds(history);
    final listenedKeys = {
      for (final song in history) '${song.source}:${song.id}',
    };

    final sections = await Future.wait(
      seeds.map((seed) async {
        final results = await Future.wait<dynamic>([
          search(seed.query, limit: 12),
          searchPlaylists(seed.query, limit: 6),
        ]);

        final outSongs = (results[0] as List<Song>)
            .where(
                (song) => !listenedKeys.contains('${song.source}:${song.id}'))
            .toList();
        final outPlaylists = results[1] as List<MusicPlaylist>;
            
        return MusicRecommendationSection(
          title: seed.title,
          songs: outSongs,
          playlists: outPlaylists,
          items: [...outSongs, ...outPlaylists],
        );
      }),
    );

    final filteredSections = sections
        .where((section) =>
            section.songs.isNotEmpty || section.playlists.isNotEmpty)
        .toList();

    return HomeFeedData(chips: [], sections: filteredSections);
  }

  static Future<List<String>> getSearchSuggestions(String query) async {
    final cleanQuery = query.trim();
    if (cleanQuery.length < 2) return [];

    final suggestions = <String>{};
    try {
      await _ensureYtInitialized();
      final ytSuggestions = await _ytMusic
          .getSearchSuggestions(cleanQuery)
          .timeout(const Duration(seconds: 5));
      suggestions.addAll(
        ytSuggestions.map(_cleanText).where((item) => item.isNotEmpty),
      );
    } catch (e) {
      debugPrint('Error getting recommendations: $e');
    }

    return suggestions.take(10).toList();
  }

  static Future<List<Song>> searchYoutubeMusic(
    String query, {
    int limit = 20,
  }) {
    final cleanQuery = query.trim();
    if (cleanQuery.isEmpty) return Future.value([]);
    return _ytSearch(cleanQuery, limit: limit);
  }

  static Future<List<MusicPlaylist>> searchPlaylists(
    String query, {
    int limit = 8,
  }) async {
    final cleanQuery = query.trim();
    if (cleanQuery.isEmpty) return [];

    try {
      await _ensureYtInitialized();
      final playlists = await _safeYtList<ytm.PlaylistDetailed>(
        'Playlist search',
        () => _ytMusic.searchPlaylists(cleanQuery),
      );

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

  static Future<List<Song>> getPlaylistSongsById(
    String playlistId, {
    String playlistTitle = 'Playlist',
    int limit = 150,
  }) async {
    final cleanId = playlistId.trim();
    if (cleanId.isEmpty) return [];

    await _ensureYtInitialized();
    for (final candidateId in _playlistIdCandidates(cleanId)) {
      try {
        final videos = await _ytMusic
            .getPlaylistVideos(candidateId)
            .timeout(const Duration(seconds: 18));

        debugPrint(
            'Playlist $playlistTitle ($candidateId): YTMusic returned ${videos.length} videos');

        if (videos.isNotEmpty) {
          final mapped = videos
              .map((video) => _songFromYtPlaylistVideo(video, playlistTitle))
              .toList();
          final filtered = mapped.where((song) => song.id.isNotEmpty).toList();
          debugPrint(
              'Playlist $playlistTitle: Mapped to ${mapped.length} songs, ${filtered.length} with valid IDs');

          final musicFiltered = filtered.where(_isLikelyMusic).toList();
          debugPrint(
              'Playlist $playlistTitle: After music filter, ${musicFiltered.length} songs remain');

          final songs = musicFiltered.take(limit).toList();

          if (songs.isNotEmpty) {
            _warmStreamCache(songs.take(4));
            return songs;
          }
        }
      } catch (e) {
        debugPrint('YTMusic playlist videos failed for $candidateId: $e');
      }
    }

    try {
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

      _warmStreamCache(songs.take(4));
      return songs;
    } catch (e) {
      debugPrint('YouTube playlist fallback failed for $cleanId: $e');
      return [];
    }
  }

  static List<String> _playlistIdCandidates(String playlistId) {
    final clean = playlistId.trim();
    if (clean.isEmpty) return const [];
    final withoutVl = clean.startsWith('VL') ? clean.substring(2) : clean;
    final withVl = clean.startsWith('VL') ? clean : 'VL$clean';
    return <String>{clean, withVl, withoutVl}
        .where((id) => id.isNotEmpty)
        .toList();
  }

  static Future<String?> getStreamUrl(String id, String source) async {
    final urls = await getStreamUrls(id, source);
    return urls.isEmpty ? null : urls.first;
  }

  static void clearStreamCache(String id, String source) {
    final cacheKey = '$source:${id.trim()}';
    _streamUrlCache.remove(cacheKey);
    _streamUrlCachedAt.remove(cacheKey);
  }

  static Future<List<String>> getStreamUrls(String id, String source,
      {bool forceRefresh = false}) async {
    final cleanId = id.trim();
    if (cleanId.isEmpty) return [];

    final cacheKey = '$source:$cleanId';
    final cachedAt = _streamUrlCachedAt[cacheKey];
    final cachedFuture = _streamUrlCache[cacheKey];

    if (!forceRefresh &&
        cachedFuture != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < _streamCacheMaxAge) {
      return cachedFuture;
    }

    if (forceRefresh) {
      _streamUrlCache.remove(cacheKey);
      _streamUrlCachedAt.remove(cacheKey);
    }

    final future = _getYoutubeStreamUrls(cleanId).then((urls) {
      if (urls.isEmpty) {
        _streamUrlCache.remove(cacheKey);
        _streamUrlCachedAt.remove(cacheKey);
      }
      return urls;
    }).catchError((Object error) {
      _streamUrlCache.remove(cacheKey);
      _streamUrlCachedAt.remove(cacheKey);
      debugPrint('Stream URL resolution failed for $cleanId: $error');
      return <String>[];
    });

    _streamUrlCache[cacheKey] = future;
    _streamUrlCachedAt[cacheKey] = DateTime.now();
    return future;
  }

  static Future<List<Song>> _ytSearch(String query,
      {required int limit}) async {
    try {
      await _ensureYtInitialized();

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
        _youtubeVideoSearch(query, limit: limit < 8 ? limit : 8),
      ]);

      final songs = _uniqueSongs(batches.expand((batch) => batch))
          .where((song) => song.id.isNotEmpty)
          .where(_isLikelyMusic)
          .toList();

      debugPrint('YTMusic search "$query" returned ${songs.length} songs.');
      _warmStreamCache(songs.take(6));
      return songs;
    } catch (e) {
      debugPrint('YTMusic search failed for "$query": $e');
      return [];
    }
  }

  static bool _isLikelyMusic(Song song) {
    final title = song.title.toLowerCase();

    // 1. CLEAR MUSIC SIGNALS (Allow immediately)
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

  static Song _songFromYtMusic(ytm.SongDetailed song) {
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

  static Song _songFromYoutubeVideo(yt.Video video) {
    var title = _cleanText(video.title, fallback: 'Unknown Track');
    var artist = _cleanText(video.author, fallback: 'Unknown Artist');
    var album = 'Online Video';
    var thumbnailUrl = video.thumbnails.highResUrl;

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

  static Future<List<String>> _getYoutubeStreamUrls(String videoId) async {
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

          // Target ~128kbps
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

  static Future<List<String>> _getPipedStreamUrls(String videoId) async {
    final completer = Completer<List<String>>();
    var errors = 0;

    for (final instance in _pipedInstances) {
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

  static bool _isAndroidFriendlyAudio(yt.AudioOnlyStreamInfo stream) {
    final container = stream.container.name.toLowerCase();
    final codec = stream.audioCodec.toLowerCase();
    return container == 'mp4' ||
        container == 'm4a' ||
        codec.contains('mp4a') ||
        codec.contains('aac');
  }

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

  static Map<String, String>? streamHeaders(String source, String id) {
    return null;
  }

  static List<Song> _uniqueSongs(Iterable<Song> songs) {
    final seen = <String>{};
    final unique = <Song>[];

    for (final song in songs) {
      final key = song.id.isEmpty
          ? '${song.source}:${_normaliseForMatch(song.title)}:${_normaliseForMatch(song.artist)}'
          : '${song.source}:${song.id}';
      if (seen.add(key)) {
        unique.add(song);
      }
    }

    return unique;
  }

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

  static double _songSearchScore(String query, Song song) {
    final q = _normaliseWords(query);
    final title = _normaliseWords(song.title);
    final artist = _normaliseWords(song.artist);
    final album = _normaliseWords(song.album);
    final tokens = q.split(' ').where((token) => token.length > 1).toList();

    var score = 0.0;
    if (title == q) score += 120;
    if (title.startsWith(q)) score += 70;
    if (title.contains(q)) score += 46;
    if (artist.contains(q)) score += 20;
    if (album.contains(q)) score += 10;

    for (final token in tokens) {
      if (title.split(' ').contains(token)) score += 7;
      if (title.contains(token)) score += 4;
      if (artist.contains(token)) score += 2.5;
      if (album.contains(token)) score += 1.5;
    }

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
    // Prefer "Song" results (which have actual album names) over "Video" results
    if (song.album != 'Music Video' && song.album != 'Online Video') {
      score += 15;
    }
    if (song.duration > 60 && song.duration < 720) score += 5;
    if (song.source == 'youtube') score += 2;
    return score;
  }

  static List<_RecommendationSeed> _recommendationSeeds(List<Song> history) {
    if (history.isEmpty) {
      return const [
        _RecommendationSeed('Trending Global Hits', 'global top hits'),
        _RecommendationSeed('Popular Music', 'trending music hits'),
        _RecommendationSeed('Lofi & Chill', 'lofi chill beats'),
        _RecommendationSeed('Bollywood Hits', 'bollywood top songs'),
        _RecommendationSeed('Pop & Dance', 'pop dance hits'),
      ];
    }

    final uniqueHistory = _uniqueSongs(history).take(120).toList();
    final profileText = uniqueHistory
        .map((song) => '${song.title} ${song.artist} ${song.album}')
        .join(' ')
        .toLowerCase();

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

    final topArtists = _topKeys(artistCounts, 5);
    final topAlbums = _topKeys(albumCounts, 3);
    final topTitles = _topKeys(titleCounts, 5);
    final topTerms = _topProfileTerms(uniqueHistory, 5);

    final seeds = <_RecommendationSeed>[];

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

    if (topTitles.isNotEmpty) {
      seeds.add(
        _RecommendationSeed(
          'Because You Listen',
          '${topTitles.take(4).join(' ')} similar songs',
        ),
      );
    }

    if (topAlbums.isNotEmpty || topTerms.isNotEmpty) {
      seeds.add(
        _RecommendationSeed(
          'More For Your Taste',
          '${[...topAlbums.take(2), ...topTerms.take(4)].join(' ')} playlist',
        ),
      );
    }

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

    final deduped = <String, _RecommendationSeed>{};
    for (final seed in seeds) {
      final query = seed.query.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (query.isEmpty) continue;
      deduped.putIfAbsent(
          seed.title, () => _RecommendationSeed(seed.title, query));
    }
    return deduped.values.take(4).toList();
  }

  static List<String> _topKeys(Map<String, int> counts, int limit) {
    final entries = counts.entries.toList()
      ..sort((a, b) {
        final countCompare = b.value.compareTo(a.value);
        if (countCompare != 0) return countCompare;
        return a.key.compareTo(b.key);
      });
    return entries.take(limit).map((entry) => entry.key).toList();
  }

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

  static void _warmStreamCache(Iterable<Song> songs) {
    // Warm up only 3 songs. Doing too many concurrently causes youtube_explode_dart
    // to spawn massive JS decryption threads, locking up the CPU for 30s+.
    for (final song in songs.take(3)) {
      unawaited(getStreamUrls(song.id, song.source));
    }
  }

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

  static String _normaliseForMatch(String value) {
    return value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
  }

  static String _normaliseWords(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
  }
}

class _RecommendationSeed {
  final String title;
  final String query;

  const _RecommendationSeed(this.title, this.query);
}
