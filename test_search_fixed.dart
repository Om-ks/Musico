import 'package:flutter/widgets.dart';
import 'lib/services/api_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final songs = await ApiService.search('ariana grande');
  print('TEST_RESULT: Found ${songs.length} songs');
  for (var s in songs.take(3)) {
    print('- ${s.title} by ${s.artist}');
  }
}
