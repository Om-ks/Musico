import 'package:http/http.dart' as http;
import 'dart:convert';

void main() async {
  final payload = {
    "videoId": "jNQXAC9IVRw",
    "context": {
      "client": {
        "clientName": "ANDROID",
        "clientVersion": "19.30.36",
        "androidSdkVersion": 31,
        "userAgent": "com.google.android.youtube/19.30.36 (Linux; U; Android 12; GB) gzip",
        "hl": "en",
        "gl": "US"
      }
    }
  };

  try {
    final res = await http.post(
      Uri.parse('https://www.youtube.com/youtubei/v1/player'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(payload),
    );
    
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
        print('No streaming data found: $data');
      }
    } else {
      print('Status: ${res.statusCode}');
    }
  } catch (e) {
    print('Failed: $e');
  }
}
