import 'package:youtube_explode_dart/youtube_explode_dart.dart';

void main() async {
  print(YoutubeExplode().runtimeType);
  
  // Just try setting up an iOS client?
  try {
     final yt = YoutubeExplode();
     print('done');
  } catch (e) {
     print(e);
  }
}
