import 'dart:io';

void main() {
  final ytService = File('lib/services/youtube_account_service.dart');
  var ytContent = ytService.readAsStringSync();
  
  // 1. Fix twoRowItemRenderer to always parse as a MusicPlaylist (Card)
  final oldTwoRowLogic = '''                if (isPlaylist || id.startsWith('VL') || id.startsWith('RD')) {
                   String finalId = id;
                   if (finalId.startsWith('VL')) finalId = finalId.substring(2);
                   playlists.add(MusicPlaylist(
                     id: finalId,
                     title: titleText,
                     owner: subtitleText,
                     thumbnailUrl: thumb,
                     itemCount: 0,
                     source: 'youtube'
                   ));
                } else {
                   if (watchEndpoint == null || watchEndpoint['videoId'] == null) continue;
                   songs.add(Song(
                     id: watchEndpoint['videoId'],
                     title: titleText,
                     artist: subtitleText,
                     album: 'YouTube Music',
                     thumbnailUrl: thumb,
                     duration: 0,
                     source: 'youtube'
                   ));
                }''';
                
  final newTwoRowLogic = '''                // In YouTube Music, twoRowItemRenderer is essentially always a card (album/playlist/artist/mix).
                // We map all of these to MusicPlaylist so they render properly as square horizontal cards.
                String finalId = id;
                if (finalId.startsWith('VL')) finalId = finalId.substring(2);
                
                playlists.add(MusicPlaylist(
                  id: finalId,
                  title: titleText,
                  owner: subtitleText,
                  thumbnailUrl: thumb,
                  itemCount: 0,
                  source: 'youtube'
                ));''';
                
  ytContent = ytContent.replaceFirst(oldTwoRowLogic, newTwoRowLogic);
  
  // 2. Add rateSong method to youtube_account_service.dart
  final rateSongMethod = '''
  Future<void> rateSong(Map<String, String> headers, String videoId, String rating) async {
    try {
      final yt = ytm.YTMusic();
      if (!yt.hasInitialized) {
        await yt.initialize(gl: 'US', hl: 'en').catchError((_) => yt);
      }
      final apiKey = yt.config['INNERTUBE_API_KEY'] ?? 'AIzaSyC1nBR9Gs1m4Hnbp6Ur0qa9Ta1IO9oPras';
      final clientVersion = yt.config['INNERTUBE_CLIENT_VERSION'] ?? '1.20240610.01.00';
      final clientName = yt.config['INNERTUBE_CONTEXT_CLIENT_NAME'] ?? 'WEB_REMIX';

      final requestHeaders = {
        ...headers,
        'Content-Type': 'application/json',
        'Origin': 'https://music.youtube.com',
      };

      // rating can be 'LIKE', 'DISLIKE', or 'INDIFFERENT'
      final endpoint = rating == 'INDIFFERENT' ? 'removelike' : 'like';

      final body = {
        'context': {
          'client': {
            'clientName': clientName,
            'clientVersion': clientVersion,
            'hl': 'en',
            'gl': 'US',
          }
        },
        'target': {
          'videoId': videoId
        }
      };

      final response = await http.post(
        Uri.parse('https://music.youtube.com/youtubei/v1/like/\$endpoint?key=\$apiKey'),
        headers: requestHeaders,
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        debugPrint('Failed to rate song: \${response.statusCode} - \${response.body}');
      } else {
        debugPrint('Successfully rated song \$videoId as \$rating');
      }
    } catch (e) {
      debugPrint('Error rating song: \$e');
    }
  }
''';

  // Insert rateSong at the end of the class
  final lastBraceIndex = ytContent.lastIndexOf('}');
  ytContent = ytContent.substring(0, lastBraceIndex) + rateSongMethod + '}\n';
  
  ytService.writeAsStringSync(ytContent);
}
