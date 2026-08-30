import 'package:dart_ytmusic_api/dart_ytmusic_api.dart';
void main() async {
  final yt = YTMusic();
  await yt.initialize(gl: 'US', hl: 'en');
  print(yt.config['visitorData']);
}
