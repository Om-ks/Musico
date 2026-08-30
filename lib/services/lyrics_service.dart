import 'dart:convert';

import 'package:dart_ytmusic_api/dart_ytmusic_api.dart' as ytm;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/song.dart';

class LyricsLine {
  final Duration timestamp;
  final String text;

  const LyricsLine({
    required this.timestamp,
    required this.text,
  });
}

class LyricsService {
  static final ytm.YTMusic _ytMusic = ytm.YTMusic();
  static Future<void>? _ytInitFuture;

  static Future<List<LyricsLine>> getLyricsForSong(Song song) async {
    if (song.source == 'youtube') {
      final youtubeLyrics = await _getYouTubeLyrics(song.id);
      if (youtubeLyrics.isNotEmpty) return youtubeLyrics;
    }

    final lrclibLyrics = await getLyrics(song.title, song.artist);
    return lrclibLyrics ?? [];
  }

  static Future<List<LyricsLine>?> getLyrics(
    String title,
    String artist,
  ) async {
    try {
      const searchUrl = kIsWeb
          ? 'https://corsproxy.io/?https://lrclib.net/api/search'
          : 'https://lrclib.net/api/search';
      final uri = Uri.parse(searchUrl).replace(
        queryParameters: {
          'track_name': _stripFeatureText(title),
          'artist_name': artist,
        },
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 7));
      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body);
      if (data is! List || data.isEmpty) return null;

      final maps = data.whereType<Map<String, dynamic>>().toList();
      if (maps.isEmpty) return null;

      final withSynced = maps.firstWhere(
        (item) {
          final lyrics = item['syncedLyrics']?.toString().trim();
          return lyrics != null && lyrics.isNotEmpty;
        },
        orElse: () => <String, dynamic>{},
      );

      if (withSynced.isNotEmpty) {
        return _parseSynced(withSynced['syncedLyrics'].toString());
      }

      final plain = maps
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

  static Future<List<LyricsLine>> _getYouTubeLyrics(String videoId) async {
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

  static List<LyricsLine> _parseSynced(String raw) {
    final lines = <LyricsLine>[];
    final matcher = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)');

    for (final rawLine in raw.split('\n')) {
      final match = matcher.firstMatch(rawLine.trim());
      if (match == null) continue;

      final fraction = match.group(3)!;
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
            RegExp(r'\s*\([^)]*(official|video|lyrics)[^)]*\)',
                caseSensitive: false),
            '')
        .replaceAll(
            RegExp(r'\s*\[[^\]]*(official|video|lyrics)[^\]]*\]',
                caseSensitive: false),
            '')
        .trim();
  }

  static Future<void> _ensureYtInitialized() {
    return _ytInitFuture ??= _ytMusic.initialize(gl: 'US', hl: 'en');
  }
}
