import re

with open('lib/services/youtube_account_service.dart', 'r', encoding='utf-8') as f:
    text = f.read()

# We want to replace the whole _fetchLikedSongs function body
pattern = r"  Future<List<Song>> _fetchLikedSongs\(Map<String, String> headers\) async \{[\s\S]*?    \} catch \(fallbackError\) \{\n      debugPrint\('YouTube _fetchLikedSongs fallback completely failed: \'\);\n      return \[\];\n    \}\n  \}"

replacement = '''  Future<List<Song>> _fetchLikedSongs(Map<String, String> headers) async {
    try {
      debugPrint('YT _fetchLikedSongs: Fetching LM (Liked Music) via Cookie Authentication...');
      // By default InnerTube VLLM endpoint fetches the Liked Music playlist
      final songs = await _fetchMusicBrowse(headers, 'VLLM', 'Liked Music');
      if (songs.isNotEmpty) {
        final finalSongs = _dedupeSongs(songs);
        debugPrint('YT _fetchLikedSongs: VLLM fetch successful. Fetched  songs.');
        return finalSongs;
      }
      return [];
    } catch (e) {
      debugPrint('YT _fetchLikedSongs VLLM failed: ');
      return [];
    }
  }'''

text = re.sub(pattern, replacement, text)

with open('lib/services/youtube_account_service.dart', 'w', encoding='utf-8') as f:
    f.write(text)
