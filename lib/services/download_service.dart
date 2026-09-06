import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/song.dart';
import 'api_service.dart';

// Service responsible for downloading music tracks to local disk for offline playback.
// Handles stream URL discovery, network streaming, progress reporting, and file integrity checks.
class DownloadService {
  // Shared HTTP client instance used for streaming audio file chunks.
  static final http.Client _http = http.Client();

  // Downloads a song to the device's local documents folder.
  // Queries candidate stream URLs from ApiService and iterates through them until one succeeds.
  // Optional onProgress callback reports completion fraction from 0.0 to 1.0.
  Future<String> downloadSong(
    Song song, {
    ValueChanged<double>? onProgress,
  }) async {
    // Obtain candidate stream URLs for the song.
    final urls = await ApiService.getStreamUrls(song.id, song.source);
    if (urls.isEmpty) {
      throw Exception('No downloadable stream found for ${song.title}');
    }

    Object? lastError;
    // Iterate through stream candidates; the first one that successfully downloads and writes returns.
    for (final url in urls) {
      try {
        return await _downloadUrl(song, url, onProgress: onProgress);
      } catch (e) {
        lastError = e;
        debugPrint('Download candidate failed for ${song.title}: $e');
      }
    }

    // Throw error if all stream candidates failed to download.
    throw Exception(lastError ?? 'Download failed for ${song.title}');
  }

  // Internal worker that streams audio bytes from a single URL into a temporary file (.part),
  // then renames it upon completion to prevent incomplete/corrupt files.
  Future<String> _downloadUrl(
    Song song,
    String url, {
    ValueChanged<double>? onProgress,
  }) async {
    final directory = await _downloadDirectory();
    final extension = _extensionFor(song.source, url);
    // Destination final audio file.
    final file = File(
      '${directory.path}${Platform.pathSeparator}${_safeFileName(song)}$extension',
    );
    // Temporary file used while download is in progress.
    final temp = File('${file.path}.part');

    // If already downloaded and exists, report 100% and return the existing file path.
    if (await file.exists()) {
      onProgress?.call(1.0);
      return file.path;
    }

    // Clean up any stale partial downloads.
    if (await temp.exists()) await temp.delete();

    // Prepare HTTP GET request with standard mobile browser headers to avoid blocking.
    final request = http.Request('GET', Uri.parse(url));
    request.headers.addAll({
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36',
      'Accept': '*/*',
      ...?ApiService.streamHeaders(song.source, song.id),
    });

    // Dispatch request with a 24-second network timeout.
    final response = await _http.send(request).timeout(
          const Duration(seconds: 24),
        );
    // Ensure HTTP status is in the 2xx success range.
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
    }

    // Read total expected content length for progress calculation.
    final totalBytes = response.contentLength ?? 0;
    var receivedBytes = 0;
    final sink = temp.openWrite();

    try {
      // Stream incoming bytes to the temporary file chunk by chunk.
      await for (final chunk in response.stream) {
        receivedBytes += chunk.length;
        sink.add(chunk);
        // Calculate and emit fractional progress (0.0 to 1.0).
        if (totalBytes > 0) {
          onProgress?.call(
            (receivedBytes / totalBytes).clamp(0.0, 1.0).toDouble(),
          );
        }
      }
    } finally {
      // Always flush and close the file sink when streaming finishes or throws.
      await sink.close();
    }

    // Atomically move the completed temp file to the final destination path.
    if (await file.exists()) await file.delete();
    await temp.rename(file.path);
    onProgress?.call(1.0);
    return file.path;
  }

  // Locates or creates the dedicated 'musico_downloads' folder inside the app's documents directory.
  Future<Directory> _downloadDirectory() async {
    final documents = await getApplicationDocumentsDirectory();
    final directory = Directory(
      '${documents.path}${Platform.pathSeparator}musico_downloads',
    );
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  // Determines the appropriate audio file extension (.webm, .mp3, or .m4a) based on the URL and source.
  String _extensionFor(String source, String url) {
    final lowerUrl = url.toLowerCase();
    if (lowerUrl.contains('.webm') || lowerUrl.contains('mime=audio/webm')) {
      return '.webm';
    }
    if (lowerUrl.contains('.mp3') || source == 'saavn') return '.mp3';
    return '.m4a';
  }

  // Sanitizes track metadata into a legal, cross-platform file name by stripping illegal characters
  // (such as slashes, colons, question marks) and truncating length.
  String _safeFileName(Song song) {
    final raw = '${song.source}_${song.id}_${song.title}_${song.artist}';
    final cleaned = raw
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    return cleaned.length > 120 ? cleaned.substring(0, 120) : cleaned;
  }
}
