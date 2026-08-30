import 'package:http/http.dart' as http;

void main() async {
  try {
    final res = await http.get(Uri.parse('https://pipedapi.in.projectsegfau.lt/streams/jNQXAC9IVRw')).timeout(Duration(seconds: 3));
    print('Status: ${res.statusCode}');
    print('Body: ${res.body}');
  } catch (e) {
    print('Failed: $e');
  }
}
