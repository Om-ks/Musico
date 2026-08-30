import re

with open('lib/services/youtube_account_service.dart', 'r', encoding='utf-8') as f:
    text = f.read()

# Let's find the start of _fetchLikedSongs and the start of Future<HomeFeedData> fetchHomeFeed
start = text.find('  Future<List<Song>> _fetchLikedSongs(Map<String, String> headers) async {')
end = text.find('  Future<HomeFeedData> fetchHomeFeed(Map<String, String> headers) async {')

if start != -1 and end != -1:
    replacement = '''  Future<List<Song>> _fetchLikedSongs(Map<String, String> headers) async {
    try {
      debugPrint('YT _fetchLikedSongs: Fetching LM (Liked Music) via Cookie Authentication...');
      final songs = await _fetchMusicBrowse(headers, 'VLLM', 'Liked Music');
      if (songs.isNotEmpty) {
        final finalSongs = _dedupeSongs(songs);
        debugPrint('YT _fetchLikedSongs: VLLM fetch successful. Fetched \ songs.');
        return finalSongs;
      }
      return [];
    } catch (e) {
      debugPrint('YT _fetchLikedSongs VLLM failed: \');
      return [];
    }
  }

'''
    text = text[:start] + replacement + text[end:]

    with open('lib/services/youtube_account_service.dart', 'w', encoding='utf-8') as f:
        f.write(text)
