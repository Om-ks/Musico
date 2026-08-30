import 'package:http/http.dart' as http;
import 'dart:convert';
void main() async {
  final uri = Uri.parse('https://music.youtube.com/youtubei/v1/browse?prettyPrint=false');
  final res = await http.post(
    uri,
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({'context': {'client': {'clientName': 'WEB_REMIX', 'clientVersion': '1.20240610.01.00', 'hl': 'en', 'gl': 'US'}}, 'browseId': 'VLPL4fGSI1pI05IQ311IEOW528nI9vMvPXYQ'})
  );
  final data = jsonDecode(res.body);
  print(data.keys.toList().toString());
}
