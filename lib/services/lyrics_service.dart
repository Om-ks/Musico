import 'dart:convert';

import 'package:dart_ytmusic_api/dart_ytmusic_api.dart' as ytm;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';

// Represents a single line of song lyrics, paired with its start time for synchronized scrolling.
class LyricsLine {
  // The exact time in the song when this line begins to be sung.
  // Set to Duration.zero for plain, non-synchronized lyrics.
  final Duration timestamp;

  // The text of this lyrical line.
  final String text;

  // Translated text of this lyrical line (optional).
  final String? translatedText;

  // Transliteration/pronunciation of this lyrical line (optional).
  final String? transliteration;

  // Constructor requiring the timestamp and line text.
  const LyricsLine({
    required this.timestamp,
    required this.text,
    this.translatedText,
    this.transliteration,
  });
  
  // Create a copy of this line with translation added
  LyricsLine copyWith({String? translatedText, String? transliteration}) {
    return LyricsLine(
      timestamp: timestamp,
      text: text,
      translatedText: translatedText ?? this.translatedText,
      transliteration: transliteration ?? this.transliteration,
    );
  }
}

// Service that retrieves song lyrics from multiple sources (YouTube Music and LRCLIB).
// Supports both synchronized (karaoke-style timecoded) lyrics and plain text lyrics.
class LyricsService {
  // YouTube Music API client used to query timecoded or plain lyrics directly from YouTube.
  static final ytm.YTMusic _ytMusic = ytm.YTMusic();

  // Memoized Future to ensure YouTube Music client is initialized only once.
  static Future<void>? _ytInitFuture;

  // In-memory cache for ultra-fast lookup during the same session.
  static final Map<String, List<LyricsLine>> _memoryCache = {};

  // Orchestrator method that attempts to retrieve lyrics for a given song.
  static Future<List<LyricsLine>> getLyricsForSong(Song song) async {
    final cacheKey = '${song.source}_${song.id}';
    
    // 1. Check in-memory cache
    if (_memoryCache.containsKey(cacheKey)) {
      return _memoryCache[cacheKey]!;
    }

    // 2. Check disk cache (SharedPreferences)
    final prefs = await SharedPreferences.getInstance();
    final cachedData = prefs.getString('lyrics_$cacheKey');
    if (cachedData != null) {
      try {
        final decoded = jsonDecode(cachedData) as List;
        final cachedLyrics = decoded.map((item) {
          final map = item as Map<String, dynamic>;
          return LyricsLine(
            timestamp: Duration(milliseconds: map['time'] as int),
            text: map['text'] as String,
            translatedText: map['trans'],
            transliteration: map['pron'],
          );
        }).toList();
        if (cachedLyrics.isNotEmpty) {
          _memoryCache[cacheKey] = cachedLyrics;
          return cachedLyrics;
        }
      } catch (e) {
        debugPrint('Failed to parse cached lyrics: $e');
      }
    }

    List<LyricsLine> result = [];

    // 3. Fetch from YouTube Music
    if (song.source == 'youtube') {
      final youtubeLyrics = await _getYouTubeLyrics(song.id);
      if (youtubeLyrics.isNotEmpty) result = youtubeLyrics;
    }

    // 4. Fallback to LRCLIB
    if (result.isEmpty) {
      final lrclibLyrics = await getLyrics(song.title, song.artist);
      if (lrclibLyrics != null && lrclibLyrics.isNotEmpty) {
        result = lrclibLyrics;
      }
    }

    // 5. Save successful fetches to memory and disk cache
    if (result.isNotEmpty) {
      _memoryCache[cacheKey] = result;
      final encoded = result.map((line) => {
        'time': line.timestamp.inMilliseconds,
        'text': line.text,
        'trans': line.translatedText,
        'pron': line.transliteration,
      }).toList();
      prefs.setString('lyrics_$cacheKey', jsonEncode(encoded));
    }

    return result;
  }

  // Searches the open-source LRCLIB API for synchronized or plain lyrics using track title and artist.
  static Future<List<LyricsLine>?> getLyrics(
    String title,
    String artist,
  ) async {
    try {
      // Use CORS proxy when running in a web browser to prevent cross-origin block.
      const searchUrl = kIsWeb
          ? 'https://corsproxy.io/?https://lrclib.net/api/search'
          : 'https://lrclib.net/api/search';
      final cleanQueryArtist = artist.split(',').first.split('&').first.split(' x ').first.trim();
      final uri = Uri.parse(searchUrl).replace(
        queryParameters: {
          'track_name': _stripFeatureText(title),
          'artist_name': cleanQueryArtist,
        },
      );
      final response = await http.get(
        uri,
        headers: {
          'User-Agent': 'Musico/1.0.0 (https://github.com/minex304-pixel/music1)'
        },
      ).timeout(const Duration(seconds: 7));
      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body);
      if (data is! List || data.isEmpty) return null;

      final maps = data.whereType<Map<String, dynamic>>().toList();
      if (maps.isEmpty) return null;

      // Strictly filter results to prevent catching wrong/fake lyrics
      final cleanTitle = _stripFeatureText(title).toLowerCase();
      final cleanArtist = artist.toLowerCase().split(',').first.trim(); // use first artist for broader match

      final validMaps = maps.where((item) {
        final trackName = item['trackName']?.toString().toLowerCase() ?? '';
        final artistName = item['artistName']?.toString().toLowerCase() ?? '';
        
        // Tokenize titles into words
        final titleWords = cleanTitle.replaceAll(RegExp(r'[^a-z0-9\s]'), ' ').split(' ').where((w) => w.length > 2).toSet();
        final trackWords = trackName.replaceAll(RegExp(r'[^a-z0-9\s]'), ' ').split(' ').where((w) => w.length > 2).toSet();
        
        // Check if at least 1 significant word matches in the title
        final trackMatch = titleWords.intersection(trackWords).isNotEmpty || trackName.contains(cleanTitle) || cleanTitle.contains(trackName);
        
        // Fuzzy artist match
        bool artistMatch = artistName.contains(cleanArtist) || cleanArtist.contains(artistName);
        if (!artistMatch) {
          final lrcWords = artistName.split(' ').where((w) => w.length > 2);
          for (final word in lrcWords) {
            if (cleanArtist.contains(word)) {
              artistMatch = true;
              break;
            }
          }
          // If artist is completely missing from YouTube channel name, but title is a strong match, allow it.
          if (!artistMatch && titleWords.intersection(trackWords).length >= 2) {
            artistMatch = true;
          }
        }
        
        return trackMatch && artistMatch;
      }).toList();

      if (validMaps.isEmpty) return null;

      // Prefer time-synchronized (LRC formatted) lyrics if available.
      final withSynced = validMaps.firstWhere(
        (item) {
          final lyrics = item['syncedLyrics']?.toString().trim();
          return lyrics != null && lyrics.isNotEmpty;
        },
        orElse: () => <String, dynamic>{},
      );

      if (withSynced.isNotEmpty) {
        return _parseSynced(withSynced['syncedLyrics'].toString());
      }

      // If no synced lyrics exist, fall back to plain text lyrics.
      final plain = validMaps
          .map((item) => item['plainLyrics']?.toString())
          .whereType<String>()
          .firstWhere((lyrics) => lyrics.trim().isNotEmpty, orElse: () => '');

      if (plain.isEmpty) return null;
      return _plainLines(plain);
    } catch (e) {
      debugPrint('LRCLIB lyrics failed: $e');
      return null;
    }
  }

  // Fetches lyrics from YouTube Music for a given videoId.
  // First tries the timed (synced) lyrics endpoint; if absent, falls back to plain lyrics.
  static Future<List<LyricsLine>> _getYouTubeLyrics(String videoId) async {
    // 1. Try timed lyrics from YouTube Music
    try {
      await _ensureYtInitialized();

      final timedLyrics = await _ytMusic
          .getTimedLyrics(videoId)
          .timeout(const Duration(seconds: 8));
      if (timedLyrics != null && timedLyrics.timedLyricsData.isNotEmpty) {
        return timedLyrics.timedLyricsData
            .map((line) {
              final cue = line.cueRange;
              return LyricsLine(
                timestamp: Duration(
                  milliseconds: cue?.startTimeMilliseconds ?? 0,
                ),
                text: (line.lyricLine ?? '').trim(),
              );
            })
            .where((line) => line.text.isNotEmpty)
            .toList();
      }
    } catch (e) {
      debugPrint('YTMusic timed lyrics failed: $e');
    }

    // 2. Fallback to static, plain lyrics from YouTube Music
    try {
      await _ensureYtInitialized();
      final plainLyrics =
          await _ytMusic.getLyrics(videoId).timeout(const Duration(seconds: 8));
      if (plainLyrics == null || plainLyrics.trim().isEmpty) return [];
      return _plainLines(plainLyrics);
    } catch (e) {
      debugPrint('YTMusic plain lyrics failed: $e');
      return [];
    }
  }

  // Parses raw LRC timestamped text (format: "[mm:ss.xx] Lyric line") into a list of LyricsLine objects.
  static List<LyricsLine> _parseSynced(String raw) {
    final lines = <LyricsLine>[];
    // Matches LRC time tags like [01:23.45] or [01:23.456] followed by the line content.
    final matcher = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)');

    for (final rawLine in raw.split('\n')) {
      final match = matcher.firstMatch(rawLine.trim());
      if (match == null) continue;

      final fraction = match.group(3)!;
      // Convert two-digit centiseconds or three-digit milliseconds into milliseconds.
      final milliseconds =
          int.parse(fraction) * (fraction.length == 2 ? 10 : 1);
      final text = match.group(4)?.trim() ?? '';
      if (text.isEmpty) continue;

      lines.add(
        LyricsLine(
          timestamp: Duration(
            minutes: int.parse(match.group(1)!),
            seconds: int.parse(match.group(2)!),
            milliseconds: milliseconds,
          ),
          text: text,
        ),
      );
    }

    return lines;
  }

  // Converts unstructured multiline plain lyrics into a list of LyricsLine objects with zero timestamps.
  static List<LyricsLine> _plainLines(String raw) {
    return raw
        .replaceAll('\r', '')
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .map((line) => LyricsLine(timestamp: Duration.zero, text: line))
        .toList();
  }

  static String _stripFeatureText(String title) {
    return title
        .replaceAll(
            RegExp(r'\s*\([^)]*(official|video|lyrics|audio|feat|ft\.)[^)]*\)',
                caseSensitive: false),
            '')
        .replaceAll(
            RegExp(r'\s*\[[^\]]*(official|video|lyrics|audio|feat|ft\.)[^\]]*\]',
                caseSensitive: false),
            '')
        .replaceAll(RegExp(r'\s*[-|]\s*topic\b', caseSensitive: false), '')
        .trim();
  }

  // Initializes YouTube Music client if not already done.
  static Future<void> _ensureYtInitialized() {
    return _ytInitFuture ??= _ytMusic.initialize(gl: 'US', hl: 'en');
  }
}
