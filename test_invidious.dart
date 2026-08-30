import 'package:http/http.dart' as http;
import 'dart:convert';

void main() async {
  final instances = [
    'https://vid.puffyan.us',
    'https://invidious.jing.rocks',
    'https://inv.tux.pizza',
  ];
  
  for (final inst in instances) {
    try {
      final res = await http.get(Uri.parse('$inst/api/v1/videos/jNQXAC9IVRw')).timeout(Duration(seconds: 3));
      print('$inst: ${res.statusCode}');
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final formatUrls = data['adaptiveFormats'].map((f) => f['url']).take(1).toList();
        print('Stream URL: $formatUrls');
      }
    } catch (e) {
      print('$inst: Failed - $e');
    }
  }
}
