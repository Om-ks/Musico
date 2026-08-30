import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/song.dart';
import 'api_service.dart';

class DownloadService {
  static final http.Client _http = http.Client();

  Future<String> downloadSong(
    Song song, {
    ValueChanged<double>? onProgress,
  }) async {
    final urls = await ApiService.getStreamUrls(song.id, song.source);
    if (urls.isEmpty) {
      throw Exception('No downloadable stream found for ${song.title}');
    }

    Object? lastError;
    for (final url in urls) {
      try {
        return await _downloadUrl(song, url, onProgress: onProgress);
      } catch (e) {
        lastError = e;
        debugPrint('Download candidate failed for ${song.title}: $e');
      }
    }

    throw Exception(lastError ?? 'Download failed for ${song.title}');
  }

  Future<String> _downloadUrl(
    Song song,
    String url, {
    ValueChanged<double>? onProgress,
  }) async {
    final directory = await _downloadDirectory();
    final extension = _extensionFor(song.source, url);
    final file = File(
      '${directory.path}${Platform.pathSeparator}${_safeFileName(song)}$extension',
    );
    final temp = File('${file.path}.part');

    if (await file.exists()) {
      onProgress?.call(1.0);
      return file.path;
    }

    if (await temp.exists()) await temp.delete();

    final request = http.Request('GET', Uri.parse(url));
    request.headers.addAll({
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36',
      'Accept': '*/*',
      ...?ApiService.streamHeaders(song.source, song.id),
    });

    final response = await _http.send(request).timeout(
          const Duration(seconds: 24),
        );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
    }

    final totalBytes = response.contentLength ?? 0;
    var receivedBytes = 0;
    final sink = temp.openWrite();

    try {
      await for (final chunk in response.stream) {
        receivedBytes += chunk.length;
        sink.add(chunk);
        if (totalBytes > 0) {
          onProgress?.call(
            (receivedBytes / totalBytes).clamp(0.0, 1.0).toDouble(),
          );
        }
      }
    } finally {
      await sink.close();
    }

    if (await file.exists()) await file.delete();
    await temp.rename(file.path);
    onProgress?.call(1.0);
    return file.path;
  }

  Future<Directory> _downloadDirectory() async {
    final documents = await getApplicationDocumentsDirectory();
    final directory = Directory(
      '${documents.path}${Platform.pathSeparator}musico_downloads',
    );
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  String _extensionFor(String source, String url) {
    final lowerUrl = url.toLowerCase();
    if (lowerUrl.contains('.webm') || lowerUrl.contains('mime=audio/webm')) {
      return '.webm';
    }
    if (lowerUrl.contains('.mp3') || source == 'saavn') return '.mp3';
    return '.m4a';
  }

  String _safeFileName(Song song) {
    final raw = '${song.source}_${song.id}_${song.title}_${song.artist}';
    final cleaned = raw
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    return cleaned.length > 120 ? cleaned.substring(0, 120) : cleaned;
  }
}
