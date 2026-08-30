import 'package:dart_ytmusic_api/dart_ytmusic_api.dart'; void main() async { final yt = YTMusic(); await yt.initialize(); final res = await yt.searchSongs('ariana grande'); print('Found  songs'); }
