import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:youtube_explode_dart/src/reverse_engineering/youtube_http_client.dart';

void main() async {
  try {
    print('Testing YoutubeExplode with iOS client configuration...');
    // We try to configure YoutubeHttpClient directly
    final httpClient = YoutubeHttpClient();
    final yt = YoutubeExplode(httpClient: httpClient);
    final manifest = await yt.videos.streamsClient.getManifest('jNQXAC9IVRw');
    print('Manifest fetched successfully.');
    yt.close();
  } catch (e) {
    print('Error: $e');
  }
}
