import 'dart:convert';
import 'package:http/http.dart' as http;

void main() async {
  final apiKey = 'AIzaSyC1nBR9Gs1m4Hnbp6Ur0qa9Ta1IO9oPras';
  final clientVersion = '1.20240610.01.00';
  
  final requestHeaders = {
    'Content-Type': 'application/json',
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36',
    'X-Youtube-Client-Name': '67',
    'X-Youtube-Client-Version': clientVersion,
    'Accept': '*/*',
    'Origin': 'https://music.youtube.com',
  };

  final body = {
    'context': {
      'client': {
        'clientName': 'WEB_REMIX',
        'clientVersion': clientVersion,
        'hl': 'en',
        'gl': 'US',
        'timeZone': 'UTC',
      }
    },
    'browseId': 'FEmusic_home',
  };

  final response = await http.post(
    Uri.parse('https://music.youtube.com/youtubei/v1/browse?key=$apiKey&prettyPrint=false'),
    headers: requestHeaders,
    body: jsonEncode(body),
  );

  if (response.statusCode == 200) {
    final data = jsonDecode(response.body);
    final contents = data['contents']?['singleColumnBrowseResultsRenderer']?['tabs']?[0]?['tabRenderer']?['content']?['sectionListRenderer']?['contents'] as List?;
    if (contents != null) {
      for (final section in contents) {
        final carousel = section['musicCarouselShelfRenderer'];
        if (carousel != null) {
          final items = carousel['contents'] as List?;
          if (items != null && items.isNotEmpty) {
             print(jsonEncode(items.first));
             break;
          }
        }
      }
    }
  }
}
