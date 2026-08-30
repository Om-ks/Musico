import 'dart:convert';
import 'package:http/http.dart' as http;

void main() async {
  final apiKey = 'AIzaSyC1nBR9Gs1m4Hnbp6Ur0qa9Ta1IO9oPras';
  
  final requestHeaders = {
    'Content-Type': 'application/json',
    'User-Agent': 'com.google.android.apps.youtube.music/6.47.52 (Linux; U; Android 13; en_US) gzip',
    'Accept': '*/*',
  };

  final body = {
    'context': {
      'client': {
        'clientName': 'ANDROID_MUSIC',
        'clientVersion': '6.47.52',
        'hl': 'en',
        'gl': 'US',
        'osName': 'Android',
        'osVersion': '13',
        'androidSdkVersion': 33,
      }
    },
    'browseId': 'FEmusic_home',
  };

  final response = await http.post(
    Uri.parse('https://music.youtube.com/youtubei/v1/browse?key=$apiKey&prettyPrint=false'),
    headers: requestHeaders,
    body: jsonEncode(body),
  );

  print(response.statusCode);
  if (response.statusCode == 200) {
    final data = jsonDecode(response.body);
    final contents = data['contents']?['singleColumnBrowseResultsRenderer']?['tabs']?[0]?['tabRenderer']?['content']?['sectionListRenderer']?['contents'] as List?;
    if (contents != null) {
      for (final section in contents) {
        final carousel = section['musicCarouselShelfRenderer'];
        if (carousel != null) {
          final items = carousel['contents'] as List?;
          if (items != null) {
            for (final item in items) {
              final twoRow = item['musicTwoRowItemRenderer'];
              if (twoRow != null) {
                final title = twoRow['title']?['runs']?[0]?['text'];
                print('Item title: $title');
              }
            }
          }
        }
      }
    }
  } else {
    print(response.body);
  }
}
