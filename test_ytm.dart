import 'package:yt_flutter_musicapi/yt_flutter_musicapi.dart';
void main() async {
  final yt = YTMusic();
  final pl = await yt.getPlaylist('VLPLw-VjHDlEOgs658kAHR_LAaILBXb-sILT');
  if (pl['tracks'] != null && pl['tracks'].isNotEmpty) {
    print(pl['tracks'][0].keys);
  }
}

