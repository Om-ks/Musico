import 'package:http/http.dart' as http;
import 'dart:convert';
void main() async {
  final uri = Uri.parse('https://music.youtube.com/youtubei/v1/browse?prettyPrint=false');
  final res = await http.post(
    uri,
    headers: {'Content-Type': 'application/json', 'X-Youtube-Client-Name': '21', 'X-Youtube-Client-Version': '6.41.52', 'Origin': 'https://music.youtube.com'},
    body: jsonEncode({'context': {'client': {'clientName': 'ANDROID_MUSIC', 'clientVersion': '6.41.52', 'hl': 'en', 'gl': 'US'}}, 'browseId': 'VLPL4fGSI1pI05IQ311IEOW528nI9vMvPXYQ'})
  );
  print(res.statusCode);
  if (res.statusCode == 200) {
    final data = jsonDecode(res.body);
    print('keys: ' + data.keys.toList().toString());
    if (data.containsKey('contents')) { print('Has contents'); }
  } else { print(res.body); }
}
