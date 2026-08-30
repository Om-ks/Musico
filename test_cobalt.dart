import 'package:http/http.dart' as http;
import 'dart:convert';

void main() async {
  try {
    final res = await http.post(
      Uri.parse('https://api.cobalt.tools/api/json'),
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'url': 'https://www.youtube.com/watch?v=jNQXAC9IVRw',
        'isAudioOnly': true,
      }),
    );
    print('Status: ${res.statusCode}');
    print('Body: ${res.body}');
  } catch (e) {
    print('Failed: $e');
  }
}
