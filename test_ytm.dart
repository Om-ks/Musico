import 'package:http/http.dart' as http;
import 'dart:convert';

void main() async {
  final payload = {
    "videoId": "jNQXAC9IVRw",
    "context": {
      "client": {
        "clientName": "WEB_REMIX",
        "clientVersion": "1.20240710.01.00",
        "hl": "en",
        "gl": "US"
      }
    }
  };

  try {
    final res = await http.post(
      Uri.parse('https://music.youtube.com/youtubei/v1/player'),
      headers: {
        'Content-Type': 'application/json',
        'Origin': 'https://music.youtube.com',
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
      },
      body: jsonEncode(payload),
    );
    
    print('Status: ${res.statusCode}');
    if (res.statusCode == 200) {
      final data = jsonDecode(res.body);
      final streamingData = data['streamingData'];
      if (streamingData != null) {
        final formats = streamingData['adaptiveFormats'] ?? streamingData['formats'];
        for (final format in formats) {
          if (format['mimeType'].contains('audio/mp4')) {
            print('Found audio/mp4 stream: ${format['url']?.substring(0, 50)}...');
            break;
          }
        }
      } else {
        print('No streaming data found: ${res.body.substring(0, 200)}');
      }
    } else {
      print('Body: ${res.body.substring(0, 200)}');
    }
  } catch (e) {
    print('Failed: $e');
  }
}
