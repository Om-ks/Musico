import 'dart:io';

void main() {
  final ap = File('lib/providers/account_provider.dart');
  var apContent = ap.readAsStringSync();
  
  final rateSongMethod = '''
  Future<void> rateSong(String videoId, bool isLiked) async {
    final headers = await getAuthHeaders();
    if (headers == null) return;
    
    // Send background rating to YT Music
    await _youtubeAccountService.rateSong(headers, videoId, isLiked ? 'LIKE' : 'INDIFFERENT');
  }
''';

  final lastBraceIndex = apContent.lastIndexOf('}');
  apContent = apContent.substring(0, lastBraceIndex) + rateSongMethod + '}\n';
  
  ap.writeAsStringSync(apContent);
}
