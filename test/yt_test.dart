import 'package:flutter_test/flutter_test.dart';
import 'package:dart_ytmusic_api/dart_ytmusic_api.dart';
void main() {
  test('fetch playlist videos', () async {
    final yt = YTMusic();
    await yt.initialize(gl: 'US', hl: 'en');
    try {
      final videos = await yt.getPlaylistVideos('PL4fGSI1pI05IQ311IEOW528nI9vMvPXYQ');
      expect(videos, isNotNull);
    } catch (e) {
      expect(e, isNotNull);
    }
  });
}
