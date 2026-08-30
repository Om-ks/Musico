import 'package:http/http.dart' as http;
import 'dart:convert';

void main() async {
  try {
    final res = await http.get(Uri.parse('https://raw.githubusercontent.com/TeamPiped/Piped-Instances/main/instances.json'));
    if (res.statusCode == 200) {
      final List data = jsonDecode(res.body);
      print('Found ${data.length} instances');
      int working = 0;
      for (final item in data) {
        final uri = item['api_url'];
        try {
           final testRes = await http.get(Uri.parse('$uri/streams/jNQXAC9IVRw')).timeout(Duration(seconds: 3));
           if (testRes.statusCode == 200) {
              final json = jsonDecode(testRes.body);
              if (json['audioStreams'] != null && json['audioStreams'].isNotEmpty) {
                 print('WORKING PIPED API: $uri');
                 working++;
                 if (working >= 5) break;
              }
           }
        } catch (e) {}
      }
      print('Total working: $working');
    }
  } catch (e) {
    print('Failed: $e');
  }
}
