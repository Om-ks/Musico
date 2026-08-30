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
    final sectionList = data['contents']?['singleColumnBrowseResultsRenderer']?['tabs']?[0]?['tabRenderer']?['content']?['sectionListRenderer'];
    if (sectionList != null) {
       final header = sectionList['header'];
       if (header != null) {
          print('Header keys: ${header.keys}');
          final chipCloud = header['chipCloudRenderer'];
          if (chipCloud != null) {
             final chips = chipCloud['chips'] as List?;
             if (chips != null) {
                for (final chip in chips) {
                   print('Chip: ${chip['chipCloudChipRenderer']?['text']?['runs']?[0]?['text']}');
                }
             }
          }
       } else {
          print('No header found in sectionListRenderer');
       }
    }
  }
}
