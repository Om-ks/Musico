with open('lib/services/youtube_account_service.dart', 'r', encoding='utf-8') as f:
    text = f.read()

import_statement = "import '../utils/sapisid.dart';\n"
if "sapisid.dart" not in text:
    text = text.replace("import 'package:flutter/foundation.dart';", "import 'package:flutter/foundation.dart';\n" + import_statement)

old_browse = '''  Future<List<Song>> _fetchMusicBrowse(
    Map<String, String> headers,
    String browseId,
    String albumName, {
    bool allowVideoFallback = true,
  }) async {
    final allSongs = <Song>[];
    String? continuationToken;

    try {
      final yt = ytm.YTMusic();
      if (!yt.hasInitialized) {
        await yt
            .initialize(gl: 'US', hl: 'en')
            .timeout(const Duration(seconds: 8))
            .catchError((_) => yt);
      }
      final apiKey = yt.config['INNERTUBE_API_KEY'] ??
          'AIzaSyC1nBR9Gs1m4Hnbp6Ur0qa9Ta1IO9oPras';
      const clientName = 'ANDROID_MUSIC';
      const clientVersion = '6.03.51';
      final requestHeaders = {
        ...headers,
        'Content-Type': 'application/json',
        'User-Agent': 'com.google.android.apps.youtube.music/6.03.51 (Linux; U; Android 13; en_US) gzip',
        'X-Youtube-Client-Name': '21',
        'X-Youtube-Client-Version': clientVersion,
        'Accept': '*/*',
        'Origin': 'https://music.youtube.com',
      };'''

new_browse = '''  Future<List<Song>> _fetchMusicBrowse(
    Map<String, String> headers,
    String browseId,
    String albumName, {
    bool allowVideoFallback = true,
  }) async {
    final allSongs = <Song>[];
    String? continuationToken;

    try {
      final yt = ytm.YTMusic();
      if (!yt.hasInitialized) {
        await yt
            .initialize(gl: 'US', hl: 'en')
            .timeout(const Duration(seconds: 8))
            .catchError((_) => yt);
      }
      final apiKey = yt.config['INNERTUBE_API_KEY'] ??
          'AIzaSyC1nBR9Gs1m4Hnbp6Ur0qa9Ta1IO9oPras';
      
      final cookieString = headers['Cookie'] ?? '';
      final sapisidHash = generateSapisidHash(cookieString);

      final requestHeaders = {
        'Cookie': cookieString,
        'Content-Type': 'application/json',
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/117.0.0.0 Safari/537.36',
        'X-Youtube-Client-Name': '67',
        'X-Youtube-Client-Version': '1.20230920.00.00',
        'X-Origin': 'https://music.youtube.com',
        'Origin': 'https://music.youtube.com',
        'Accept': '*/*',
        if (sapisidHash.isNotEmpty) 'Authorization': sapisidHash,
      };'''

text = text.replace(old_browse, new_browse)

with open('lib/services/youtube_account_service.dart', 'w', encoding='utf-8') as f:
    f.write(text)
