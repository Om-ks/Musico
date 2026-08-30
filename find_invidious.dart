import 'package:http/http.dart' as http;
import 'dart:convert';

void main() async {
  try {
    final res = await http.get(Uri.parse('https://api.invidious.io/instances.json'));
    if (res.statusCode == 200) {
      final List data = jsonDecode(res.body);
      for (final item in data) {
        final info = item[1];
        if (info['type'] == 'https' && info['api'] == true) {
          final uri = info['uri'];
          print('Testing $uri...');
          try {
             final testRes = await http.get(Uri.parse('$uri/api/v1/videos/jNQXAC9IVRw')).timeout(Duration(seconds: 3));
             if (testRes.statusCode == 200) {
                print('WORKING: $uri');
                break;
             }
          } catch (e) {}
        }
      }
    }
  } catch (e) {
    print('Failed: $e');
  }
}
