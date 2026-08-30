import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

void main() async {
  final yt = YoutubeExplode();
  final stopwatch = Stopwatch()..start();
  
  try {
    print('Testing youtube_explode_dart...');
    final manifest = await yt.videos.streamsClient.getManifest('jNQXAC9IVRw');
    print('youtube_explode_dart took: ${stopwatch.elapsedMilliseconds} ms');
    print('Audio Streams: ${manifest.audioOnly.length}');
  } catch (e) {
    print('youtube_explode_dart error: $e');
  } finally {
    yt.close();
  }
}
