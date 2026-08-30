with open('lib/services/youtube_account_service.dart', 'r', encoding='utf-8') as f:
    text = f.read()

old_fetch_liked = '''  Future<List<Song>> _fetchLikedSongs(Map<String, String> headers) async {
    // LAYER 1: Data API (Perfect Chronological, Full 800+ List, No Web Remix Truncation)
    try {
      debugPrint('YT _fetchLikedSongs: Try Layer 1 (Data API) for full list...');
      
      final items = await _fetchPagedItems(
        headers,
        'playlistItems',
        {
          'part': 'snippet,contentDetails',
          'playlistId': 'LL', // Reverted to LL: Data API does not support LM directly
          'maxResults': '50',
        },
        maxPages: 60,
      );

      debugPrint('YT _fetchLikedSongs: Layer 1 returned  items. Filtering...');
      
      final enrichedSongs = <Song>[];
      for (final item in items) {
        final snippet = item['snippet'] as Map<String, dynamic>? ?? {};
        final vidId = snippet['resourceId']?['videoId'] as String?;
        final title = snippet['title'] as String?;
        final channel = snippet['videoOwnerChannelTitle'] as String?;
        final publishedAt = snippet['publishedAt'] as String?;
        final addedAtStr = item['snippet']?['publishedAt'] as String?;
        final addedAt = addedAtStr != null ? DateTime.tryParse(addedAtStr) : DateTime.now();

        if (vidId != null && _isMusicVideo(snippet)) {
          final s = Song(
            id: vidId,
            title: _cleanTitle(title ?? 'Unknown'),
            artist: channel ?? 'Unknown',
            duration: '', 
            thumbnailUrl: _getThumbnail(snippet),
            source: 'youtube',
            originalId: vidId,
            url: 'https://youtube.com/watch?v=',
            addedAt: addedAt,
          );
          enrichedSongs.add(s);
        }
      }

      final finalSongs = _dedupeSongs(enrichedSongs);
      debugPrint('YT _fetchLikedSongs: Data API fetched  songs.');
      return finalSongs;
    } catch (e) {
      debugPrint('YouTube _fetchLikedSongs (Data API) failed, quota exceeded: ');
    }

    // LAYER 2: InnerTube VLLM (Fallback when quota dead)
    try {
      debugPrint('YT _fetchLikedSongs: Data API failed. Trying Layer 2 (InnerTube VLLM)...');
      final songs = await _fetchMusicBrowse(headers, 'VLLM', 'Liked Music');
      if (songs.isNotEmpty) {
        final finalSongs = _dedupeSongs(songs);
        debugPrint('YT _fetchLikedSongs: VLLM fetch successful. Fetched  songs.');
        return finalSongs;
      }
    } catch (e) {
      debugPrint('YT _fetchLikedSongs VLLM failed: ');
    }

    // LAYER 3: InnerTube LM (Hard capped 260)
    try {
      debugPrint('YT _fetchLikedSongs: Data API failed. Trying Layer 3 (InnerTube LM max 260)...');
      final lmSongs = await _fetchMusicBrowse(headers, 'VLLM', 'Liked Music');
      final finalLmSongs = _dedupeSongs(lmSongs);
      debugPrint('YT _fetchLikedSongs: LM Fallback successful. Fetched  songs.');
      return finalLmSongs;
    } catch (fallbackError) {
      debugPrint('YouTube _fetchLikedSongs fallback completely failed: ');
      return [];
    }
  }'''

new_fetch_liked = '''  Future<List<Song>> _fetchLikedSongs(Map<String, String> headers) async {
    try {
      debugPrint('YT _fetchLikedSongs: Fetching VLLM via Cookie Authentication...');
      final songs = await _fetchMusicBrowse(headers, 'VLLM', 'Liked Music');
      final finalSongs = _dedupeSongs(songs);
      debugPrint('YT _fetchLikedSongs: VLLM fetch successful. Fetched  songs.');
      return finalSongs;
    } catch (e) {
      debugPrint('YT _fetchLikedSongs VLLM failed: ');
      return [];
    }
  }'''

text = text.replace(old_fetch_liked, new_fetch_liked)

# We need to make _fetchMusicBrowse pass the cookies properly and use SAPISIDHASH
with open('lib/services/youtube_account_service.dart', 'w', encoding='utf-8') as f:
    f.write(text)
