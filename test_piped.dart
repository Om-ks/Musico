import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';

void main() async {
  final _pipedInstances = [
    'https://pipedapi.kavin.rocks',
    'https://pipedapi.smnz.de',
    'https://pipedapi.lunar.icu',
    'https://pipedapi.in.projectsegfau.lt',
    'https://pipedapi.us.projectsegfau.lt',
  ];

  for (final instance in _pipedInstances) {
    try {
      final sw = Stopwatch()..start();
      final res = await http.get(Uri.parse('$instance/streams/jNQXAC9IVRw')).timeout(Duration(seconds: 3));
      print('$instance: ${res.statusCode} (${sw.elapsedMilliseconds} ms)');
    } catch (e) {
      print('$instance: failed - $e');
    }
  }
}
