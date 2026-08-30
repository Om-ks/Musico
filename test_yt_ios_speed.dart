import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:youtube_explode_dart/src/reverse_engineering/youtube_http_client.dart';
import 'package:http/http.dart' as http;

void main() async {
  final httpClient = YoutubeHttpClient();
  final yt = YoutubeExplode(httpClient: httpClient);
  final stopwatch = Stopwatch()..start();
  
  try {
    print('Testing YoutubeExplode iOS speed...');
    final manifest = await yt.videos.streamsClient.getManifest('jNQXAC9IVRw');
    print('Manifest took: ${stopwatch.elapsedMilliseconds} ms');
    
    final audioStream = manifest.audioOnly.withHighestBitrate();
    
    stopwatch.reset();
    final res = await http.Client().send(http.Request('GET', audioStream.url));
    var bytes = 0;
    res.stream.listen((chunk) {
      bytes += chunk.length;
      if (bytes > 1024 * 500) { // 500 KB
         print('Downloaded 500KB in ${stopwatch.elapsedMilliseconds} ms!');
         yt.close();
         return;
      }
    });
  } catch (e) {
    print('Error: $e');
  }
}
