import 'package:http/http.dart' as http;
import 'dart:convert';
void main() async {
  final uri = Uri.parse('https://music.youtube.com/youtubei/v1/browse?key=AIzaSyC1nBR9Gs1m4Hnbp6Ur0qa9Ta1IO9oPras&prettyPrint=false');
  final res = await http.post(
    uri,
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({'context': {'client': {'clientName': 'WEB_REMIX', 'clientVersion': '1.20240610.01.00', 'hl': 'en', 'gl': 'US'}}, 'browseId': 'VLPL4fGSI1pI05IQ311IEOW528nI9vMvPXYQ'})
  );
  print(res.statusCode);
  if (res.statusCode == 200) {
    final data = jsonDecode(res.body);
    print('keys: ' + data.keys.toList().toString());
    if (data.containsKey('contents')) { print('Has contents'); }
  } else { print(res.body); }
}
