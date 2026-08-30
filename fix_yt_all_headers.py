import re

with open('lib/services/youtube_account_service.dart', 'r', encoding='utf-8') as f:
    text = f.read()

# Make sure sapisid is imported
if 'sapisid.dart' not in text:
    text = text.replace("import 'package:flutter/foundation.dart';", "import 'package:flutter/foundation.dart';\nimport '../utils/sapisid.dart';")

helper_func = '''
  Map<String, String> _buildInnerTubeHeaders(Map<String, String> baseHeaders) {
    final cookieString = baseHeaders['Cookie'] ?? '';
    final sapisidHash = generateSapisidHash(cookieString);

    return {
      'Cookie': cookieString,
      'Content-Type': 'application/json',
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/117.0.0.0 Safari/537.36',
      'X-Youtube-Client-Name': '67',
      'X-Youtube-Client-Version': '1.20230920.00.00',
      'X-Origin': 'https://music.youtube.com',
      'Origin': 'https://music.youtube.com',
      'Accept': '*/*',
      if (sapisidHash.isNotEmpty) 'Authorization': sapisidHash,
    };
  }
'''

if '_buildInnerTubeHeaders' not in text:
    text = text.replace('class YoutubeAccountService {', 'class YoutubeAccountService {' + helper_func)

# 1. fetchHomeFeed
text = re.sub(r"      final requestHeaders = \{[\s\S]*?'Origin': 'https://music\.youtube\.com',[\s\S]*?\};", "      final requestHeaders = _buildInnerTubeHeaders(headers);", text)

# 2. _fetchMusicBrowse (which might have been partially modified)
text = re.sub(r"      final cookieString = headers\['Cookie'\] \?\? '';[\s\S]*?if \(sapisidHash\.isNotEmpty\) 'Authorization': sapisidHash,\n      \};", "      final requestHeaders = _buildInnerTubeHeaders(headers);", text)

# 3. fetchRecents
# 4. _fetchPagedItems (Wait, Data API doesn't use InnerTube, it uses standard headers. Wait, Data API uses Authorization: Bearer token... but we don't have token anymore. Oh! Data API is completely broken without OAuth!)
# If Data API is broken, _fetchPagedItems must be removed or avoided. But we already avoided it in _fetchLikedSongs by replacing it entirely. We also need to avoid Data API for etchPlaylists and etchPlaylistSongs.

with open('lib/services/youtube_account_service.dart', 'w', encoding='utf-8') as f:
    f.write(text)
