import 'dart:async';
import 'package:flutter/foundation.dart';
import '../utils/sapisid.dart';

import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:dart_ytmusic_api/dart_ytmusic_api.dart' as ytm;

import '../models/account_library.dart';
import '../models/music_playlist.dart';
import '../models/song.dart';
import 'api_service.dart';

/// [YoutubeAccountService] handles all YouTube Music communication for the app.
///
/// It connects directly to YouTube Music's internal API (codenamed "InnerTube")
/// using the user's browser cookies. This allows the app to fetch real YouTube Music
/// data such as Liked Songs, personalized playlists, the home recommendation feed,
/// and perform actions like creating playlists and liking songs.
class YoutubeAccountService {
  /// Temporary cache of song/playlist items deleted during the current app session.
  ///
  /// Why this is needed:
  /// When a user deletes a song or playlist, YouTube's servers can take several
  /// seconds or even minutes to propagate the change. By storing deleted item IDs
  /// in memory here, we can filter them out immediately from API responses so the
  /// user sees instant visual feedback without deleted items reappearing.
  static final Set<String> _deletedPlaylistItems = {};

  /// Constructs the specific HTTP headers required by YouTube Music's internal API ("InnerTube").
  ///
  /// What it does:
  /// YouTube Music's web client uses custom headers to verify requests. This method takes
  /// the user's raw session cookies, calculates a special cryptographic authorization token
  /// called `SAPISIDHASH` (via [generateSapisidHash]), and attaches YouTube Music's web client
  /// identifiers (Client Name `67` = YouTube Music Web).
  ///
  /// Parameters:
  /// - [baseHeaders]: The incoming headers containing the user's authentication `Cookie`.
  ///
  /// Returns:
  /// - A [Map<String, String>] containing all necessary headers to make authenticated
  ///   InnerTube POST requests to `https://music.youtube.com/youtubei/v1/*`.
  Map<String, String> _buildInnerTubeHeaders(Map<String, String> baseHeaders) {
    final cookieString = baseHeaders['Cookie'] ?? '';
    // Generate the SAPISID authorization hash from the user's cookies
    final sapisidHash = generateSapisidHash(cookieString);

    return {
      'Cookie': cookieString,
      'Content-Type': 'application/json',
      // Disguise request as a modern desktop Chrome browser on Windows
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/117.0.0.0 Safari/537.36',
      // Client 67 identifies this request specifically as YouTube Music Web
      'X-Youtube-Client-Name': '67',
      'X-Youtube-Client-Version': '1.20230920.00.00',
      'X-Origin': 'https://music.youtube.com',
      'Origin': 'https://music.youtube.com',
      'Accept': '*/*',
      // If SAPISID cookie was present, attach the calculated authorization header
      if (sapisidHash.isNotEmpty) 'Authorization': sapisidHash,
    };
  }

  /// Base URL for the official Google YouTube Data API v3 (used as a fallback).
  static const _base = 'https://www.googleapis.com/youtube/v3/';

  /// Parses a raw subtitle string from YouTube into a clean description and song count.
  ///
  /// What it does:
  /// YouTube often formats card subtitles as compound strings like:
  /// "Playlist • 45 songs • 1.2M views" or "Album • The Beatles • 1969".
  /// This helper uses regular expressions to extract the numeric song count (if present)
  /// and strips out unwanted prefixes and metadata to leave a clean title/artist name.
  ///
  /// Parameters:
  /// - [raw]: The unparsed subtitle text from YouTube's response.
  ///
  /// Returns:
  /// - A record `({String subtitle, int count})`:
  ///   - `subtitle`: The cleaned-up text (e.g., creator name or album type).
  ///   - `count`: Total number of songs parsed from the text, or 0 if none found.
  ({String subtitle, int count}) _parseSubtitleAndCount(String raw) {
    if (raw.isEmpty) return (subtitle: '', count: 0);
    int count = 0;
    // Look for numbers followed by "song" or "songs" (e.g. "25 songs")
    final match = RegExp(r'(\d+)\s+songs?').firstMatch(raw);
    if (match != null) {
      count = int.tryParse(match.group(1)!) ?? 0;
    }
    // Remove leading category indicators like "Playlist • " or "Album • "
    String clean = raw.replaceAll(RegExp(r'^(?:Playlist|Album|EP|Single)\s*•\s*'), '').trim();
    // Remove trailing view/play/song count metadata
    clean = clean.replaceAll(RegExp(r'\s*•\s*[\d,.]+[KMBkmb]?\s+(?:views?|plays?|songs?)'), '').trim();
    // Remove trailing release year (e.g., "• 2024")
    clean = clean.replaceAll(RegExp(r'\s*•\s*\d{4}$'), '').trim();
    return (subtitle: clean, count: count);
  }

  /// Fetches the user's complete library: Liked Songs, Recent Songs, and Playlists.
  ///
  /// What it does:
  /// Coordinates fetching all parts of the user's music library in one place.
  /// It runs each fetch sequentially with a small pause (300ms) between calls to prevent
  /// YouTube servers from blocking us due to rapid-fire requests. Each call has its own
  /// timeout so a single slow request will not hang the entire app.
  ///
  /// Parameters:
  /// - [headers]: The HTTP headers containing the user's auth cookies.
  ///
  /// Returns:
  /// - An [AccountLibrary] object containing lists of [Song]s and [MusicPlaylist]s.
  ///   If an overall error occurs, returns [AccountLibrary.empty].
  Future<AccountLibrary> fetchLibrary(Map<String, String> headers) async {
    debugPrint('YouTubeAccountService: Starting fetchLibrary...');
    List<Song> likedSongs = [];
    List<Song> recentSongs = [];
    List<MusicPlaylist> playlists = [];

    int failCount = 0;

    try {
      // Step 1: Fetch the user's Liked Songs (VLLM playlist)
      // Generous timeout (150s) because Liked Songs can contain thousands of tracks
      debugPrint('YouTubeAccountService: Fetching Liked Songs...');
      likedSongs = await _fetchLikedSongs(headers)
          .timeout(const Duration(seconds: 150))
          .catchError((e) {
        debugPrint('YouTube _fetchLikedSongs failed: $e');
        failCount++;
        return <Song>[];
      });
      // Short delay to avoid rate limiting
      await Future.delayed(const Duration(milliseconds: 300));

      // Step 2: Fetch recently played songs (currently relies on local history)
      debugPrint('YouTubeAccountService: Fetching Recents...');
      recentSongs = await fetchRecents(headers)
          .timeout(const Duration(seconds: 15))
          .catchError((e) {
        debugPrint('YouTube fetchRecents failed: $e');
        failCount++;
        return <Song>[];
      });
      // Short delay to avoid rate limiting
      await Future.delayed(const Duration(milliseconds: 300));

      // Step 3: Fetch the user's created and saved playlists
      debugPrint('YouTubeAccountService: Fetching Playlists...');
      playlists = await fetchPlaylists(headers)
          .timeout(const Duration(seconds: 75))
          .catchError((e) {
        debugPrint('YouTube fetchPlaylists failed: $e');
        failCount++;
        return <MusicPlaylist>[];
      });

      // Log a warning if all requests failed, but avoid throwing to keep app stable
      if (failCount == 3 ||
          (likedSongs.isEmpty && recentSongs.isEmpty && playlists.isEmpty)) {
        debugPrint(
            'YouTubeAccountService: All fetch operations failed or returned empty.');
      }

      debugPrint(
          'YouTubeAccountService: fetchLibrary complete. Liked: ${likedSongs.length}');
      return AccountLibrary(
        likedSongs: likedSongs,
        recentSongs: recentSongs,
        playlists: playlists,
      );
    } catch (e) {
      debugPrint('YouTube fetchLibrary overall failed: $e');
      return AccountLibrary.empty;
    }
  }

  /// Internal helper to fetch the user's "Liked Music" auto-playlist.
  ///
  /// What it does:
  /// Uses YouTube Music's browse endpoint with browse ID `'VLLM'` ("View Liked Music").
  /// It filters out any tracks that were deleted or unliked during the current session
  /// by checking against [_deletedPlaylistItems].
  ///
  /// Parameters:
  /// - [headers]: User's authentication headers with cookies.
  ///
  /// Returns:
  /// - A [List<Song>] containing all parsed liked songs, or an empty list on failure.
  Future<List<Song>> _fetchLikedSongs(Map<String, String> headers) async {
    try {
      debugPrint('YT _fetchLikedSongs: Fetching LM (Liked Music) via Cookie Authentication...');
      // 'VLLM' is the internal YouTube Music browse ID for Liked Music
      final songs = await _fetchMusicBrowse(headers, 'VLLM', 'Liked Music');
      if (songs.isNotEmpty) {
        // Exclude songs that were unliked during this session
        final finalSongs = songs.where((s) => 
          !_deletedPlaylistItems.contains('LM_${s.id}') && 
          !_deletedPlaylistItems.contains('VLLM_${s.id}')).toList();
        debugPrint('YT _fetchLikedSongs: VLLM fetch successful. Fetched ${finalSongs.length} songs.');
        return finalSongs;
      }
      return [];
    } catch (e) {
      debugPrint('YT _fetchLikedSongs VLLM failed: ');
      return [];
    }
  }

  /// Fetches the YouTube Music "Home" feed, including filter chips and recommended shelves.
  ///
  /// What it does:
  /// Requests the personalized YouTube Music Home screen (`FEmusic_home`), which contains
  /// mood/genre filter chips (e.g. "Relax", "Workout", "Energize") and various horizontal
  /// shelves of music (e.g. "Quick picks", "Recommended albums", "Mixed for you").
  ///
  /// Parameters:
  /// - [headers]: User auth headers containing session cookies.
  /// - [params]: Optional token string passed when a user selects a specific filter chip.
  ///   If provided, YouTube returns a home feed filtered for that mood/genre.
  ///
  /// Returns:
  /// - A [HomeFeedData] containing:
  ///   - `chips`: List of [HomeFeedChip] category pills shown at the top of the screen.
  ///   - `sections`: List of [MusicRecommendationSection] shelves containing songs & playlists.
  Future<HomeFeedData> fetchHomeFeed(Map<String, String> headers, {String? params}) async {
    final sections = <MusicRecommendationSection>[];
    final chips = <HomeFeedChip>[];
    try {
      // Initialize the dart_ytmusic_api helper to obtain active InnerTube client configuration
      final yt = ytm.YTMusic();
      if (!yt.hasInitialized) {
        await yt.initialize(gl: 'US', hl: 'en').catchError((_) => yt);
      }
      // InnerTube API key and client configuration defaults for YouTube Music Web ("WEB_REMIX")
      final apiKey = yt.config['INNERTUBE_API_KEY'] ?? 'AIzaSyC1nBR9Gs1m4Hnbp6Ur0qa9Ta1IO9oPras';
      final clientName = yt.config['INNERTUBE_CONTEXT_CLIENT_NAME'] ?? 'WEB_REMIX';
      final clientVersion = yt.config['INNERTUBE_CLIENT_VERSION'] ?? '1.20240610.01.00';
      
      // Build authenticated headers with SAPISID authorization
      final requestHeaders = _buildInnerTubeHeaders(headers);

      // YouTube Music InnerTube API requires a 'context' block detailing the client environment
      final Map<String, dynamic> body = {
        'context': {
          'client': {
            'clientName': clientName,
            'clientVersion': clientVersion,
            'hl': 'en',
            'gl': 'US',
            'timeZone': 'UTC',
          }
        },
      };
      
      // 'FEmusic_home' is the canonical browse ID for YouTube Music's Home feed
      body['browseId'] = 'FEmusic_home';
      // If user tapped a filter chip (e.g., Workout), attach its continuation params
      if (params != null) {
        body['params'] = params;
      }

      // Perform HTTP POST to the InnerTube browse endpoint
      final response = await http.post(
        Uri.parse('https://music.youtube.com/youtubei/v1/browse?key=$apiKey&prettyPrint=false'),
        headers: requestHeaders,
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        
        // --- PARSING YOUTUBE MUSIC JSON STRUCTURE ---
        // Top-level feed sections live inside:
        // contents -> singleColumnBrowseResultsRenderer -> tabs[0] -> tabRenderer -> content -> sectionListRenderer
        // Or under continuationContents for paginated responses.
        final sectionList = data['contents']?['singleColumnBrowseResultsRenderer']?['tabs']?[0]?['tabRenderer']?['content']?['sectionListRenderer'] ??
            data['continuationContents']?['sectionListContinuation'];
            
        if (sectionList != null) {
          // --- EXTRACT FILTER CHIPS ---
          // Chips (e.g. "Energize", "Workout", "Focus") are located in:
          // sectionList -> header -> chipCloudRenderer -> chips
          final headerChips = sectionList['header']?['chipCloudRenderer']?['chips'] as List?;
          if (headerChips != null) {
            for (final chip in headerChips) {
              final renderer = chip['chipCloudChipRenderer'];
              final text = renderer?['text']?['runs']?[0]?['text']?.toString();
              // 'params' contains the token needed to reload the feed filtered by this chip
              final chipParams = renderer?['navigationEndpoint']?['browseEndpoint']?['params']?.toString();
              if (text != null && text.isNotEmpty) {
                chips.add(HomeFeedChip(text: text, token: chipParams));
              }
            }
          }

          final contents = sectionList['contents'] as List?;
          if (contents != null) {
            // --- PASS 1: EXTRACT "FROM YOUR LIBRARY" SHELF ---
            // YouTube Music places user library items (recent playlists/mixes) inside
            // an 'itemSectionRenderer'. We parse this first and insert it at index 0 so
            // the user's personal content appears prominently at the top of Home.
            for (final section in contents) {
              if (!section.containsKey('itemSectionRenderer')) continue;
              final itemSection = section['itemSectionRenderer'];
              final itemContents = itemSection?['contents'] as List?;
              if (itemContents == null) continue;
              for (final itemContent in itemContents) {
                final shelf = itemContent['musicCarouselShelfRenderer'] ?? itemContent['musicShelfRenderer'];
                if (shelf == null) continue;
                final shelfHeader = shelf['header']?['musicCarouselShelfBasicHeaderRenderer'];
                final shelfTitleRuns = shelfHeader?['title']?['runs'] as List?;
                final shelfTitle = shelfTitleRuns?.map((r) => r['text']?.toString() ?? '').join('') ?? 'From your library';
                final shelfItems = shelf['contents'] as List?;
                if (shelfItems == null || shelfItems.isEmpty) continue;
                final shelfPlaylists = <MusicPlaylist>[];
                final shelfMixed = <dynamic>[];
                for (final item in shelfItems) {
                  final twoRow = item['musicTwoRowItemRenderer'];
                  if (twoRow == null) continue;
                  // Card navigation can be a playlist, radio, or video watch endpoint
                  final watchEndpoint = twoRow['navigationEndpoint']?['watchEndpoint'];
                  final playlistEndpoint = twoRow['navigationEndpoint']?['watchPlaylistEndpoint'];
                  final browseEndpoint = twoRow['navigationEndpoint']?['browseEndpoint'];
                  final playlistId = playlistEndpoint?['playlistId']?.toString() ??
                             watchEndpoint?['playlistId']?.toString() ??
                             browseEndpoint?['browseId']?.toString();
                  if (playlistId == null) continue;
                  final titleText = twoRow['title']?['runs']?[0]?['text']?.toString() ?? 'Unknown';
                  final rawSubtitle = (twoRow['subtitle']?['runs'] as List?)?.map((r) => r['text']?.toString() ?? '').join('') ?? '';
                  final parsedInfo = _parseSubtitleAndCount(rawSubtitle);
                  final thumbnails = twoRow['thumbnailRenderer']?['musicThumbnailRenderer']?['thumbnail']?['thumbnails'] as List?;
                  String thumb = (thumbnails != null && thumbnails.isNotEmpty) ? thumbnails.last['url']?.toString() ?? '' : '';
                  if (thumb.startsWith('//')) thumb = 'https:$thumb';
                  // Remove 'VL' (View List) prefix from playlist ID for consistent internal format
                  String finalId = playlistId.startsWith('VL') ? playlistId.substring(2) : playlistId;
                  final p = MusicPlaylist(id: finalId, title: titleText, owner: parsedInfo.subtitle, thumbnailUrl: thumb, itemCount: parsedInfo.count, source: 'youtube');
                  shelfPlaylists.add(p);
                  shelfMixed.add(p);
                }
                if (shelfPlaylists.isNotEmpty) {
                  sections.insert(0, MusicRecommendationSection(title: shelfTitle, songs: [], playlists: shelfPlaylists, items: shelfMixed));
                }
              }
            }

            // --- PASS 2: EXTRACT RECOMMENDATION CAROUSELS ---
            // YouTube Music organizes recommendations into horizontal carousels
            // (e.g. "Quick picks", "Forgotten favorites", "Mixed for you").
            // They appear under 'musicCarouselShelfRenderer' or 'musicImmersiveCarouselShelfRenderer'.
            for (final section in contents) {
            if (section.containsKey('itemSectionRenderer')) continue;
            
            final carousel = section['musicCarouselShelfRenderer'] ?? section['musicImmersiveCarouselShelfRenderer'] ?? section['musicShelfRenderer'];
            if (carousel == null) continue;
            
              // Extract the carousel shelf title (combining optional strapline like "SIMILAR TO" + "Dua Lipa")
              final header = carousel['header']?['musicCarouselShelfBasicHeaderRenderer'];
              final titleRuns = header?['title']?['runs'] as List?;
              final straplineRuns = header?['strapline']?['runs'] as List?;
              
              String title = titleRuns?.map((r) => r['text']?.toString() ?? '').join('') ?? 'Recommended';
              final strapline = straplineRuns?.map((r) => r['text']?.toString() ?? '').join('') ?? '';
              
              if (strapline.isNotEmpty) {
                title = strapline + ' ' + title;
              }

            final items = carousel['contents'] as List?;
            if (items == null || items.isEmpty) continue;
            
            final songs = <Song>[];
            final playlists = <MusicPlaylist>[];
            final mixedItems = <dynamic>[];
            
            // Loop through each item inside this carousel shelf
            for (final item in items) {
              final twoRow = item['musicTwoRowItemRenderer'];
              final responsive = item['musicResponsiveListItemRenderer'];
              
              // Case A: Item is a TwoRow renderer (vertical card with image + 2 lines of text)
              // Used for albums, playlists, mixes, or individual song cards
              if (twoRow != null) {
                final watchEndpoint = twoRow['navigationEndpoint']?['watchEndpoint'];
                final playlistEndpoint = twoRow['navigationEndpoint']?['watchPlaylistEndpoint'];
                final browseEndpoint = twoRow['navigationEndpoint']?['browseEndpoint'];
                
                final playlistId = playlistEndpoint?['playlistId']?.toString() ??
                           watchEndpoint?['playlistId']?.toString() ??
                           browseEndpoint?['browseId']?.toString();
                final videoId = watchEndpoint?['videoId']?.toString();
                           
                if (playlistId == null && videoId == null) continue;
                
                final titleText = twoRow['title']?['runs']?[0]?['text']?.toString() ?? 'Unknown';
                
                final rawSubtitle = (twoRow['subtitle']?['runs'] as List?)?.map((r) => r['text']?.toString() ?? '').join('') ?? '';
                final parsedInfo = _parseSubtitleAndCount(rawSubtitle);
                
                final thumbnails = twoRow['thumbnailRenderer']?['musicThumbnailRenderer']?['thumbnail']?['thumbnails'] as List?;
                String thumb = (thumbnails != null && thumbnails.isNotEmpty) ? thumbnails.last['url']?.toString() ?? '' : '';
                if (thumb.startsWith('//')) thumb = 'https:$thumb';
                
                // If it has a videoId and no browseEndpoint, treat it as an individual playable Song
                if (videoId != null && videoId.isNotEmpty && browseEndpoint == null) {
                  final s = Song(
                    id: videoId,
                    title: titleText,
                    artist: parsedInfo.subtitle,
                    album: 'YouTube Music',
                    thumbnailUrl: thumb,
                    duration: 0,
                    source: 'youtube'
                  );
                    songs.add(s);
                    mixedItems.add(s);
                // Otherwise if it has a playlistId, treat it as a MusicPlaylist
                } else if (playlistId != null && playlistId.isNotEmpty) {
                  String finalId = playlistId.startsWith('VL') ? playlistId.substring(2) : playlistId;
                  final p = MusicPlaylist(
                    id: finalId,
                    title: titleText,
                    owner: parsedInfo.subtitle,
                    thumbnailUrl: thumb,
                    itemCount: parsedInfo.count,
                    source: 'youtube'
                  );
                    playlists.add(p);
                    mixedItems.add(p);
                }
              // Case B: Item is a Responsive List Item (horizontal row with columns)
              // Typically used for songs inside "Quick picks" shelves
              } else if (responsive != null) {
                final flexColumns = responsive['flexColumns'] as List?;
                if (flexColumns == null || flexColumns.isEmpty) continue;
                
                // Column 0 contains the Song Title
                final titleRuns = (flexColumns[0]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'] as List?);
                final titleText = titleRuns?[0]?['text']?.toString() ?? 'Unknown';
                
                // Column 1 contains Artist, Album, and duration info
                final subtitleRuns = (flexColumns.length > 1) 
                    ? (flexColumns[1]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'] as List?)
                    : null;
                final rawSubtitle = subtitleRuns?.map((r) => r['text']?.toString() ?? '').join('') ?? '';
                final parsedInfo = _parseSubtitleAndCount(rawSubtitle);
                
                // Thumbnail image
                final thumbnails = responsive['thumbnail']?['musicThumbnailRenderer']?['thumbnail']?['thumbnails'] as List?;
                String thumb = (thumbnails != null && thumbnails.isNotEmpty) ? thumbnails.last['url']?.toString() ?? '' : '';
                if (thumb.startsWith('//')) thumb = 'https:$thumb';
                
                // Extract video ID from play button overlay navigation endpoint
                final overlay = responsive['overlay']?['musicItemThumbnailOverlayRenderer']?['content']?['musicPlayButtonRenderer'];
                final watchEndpoint = overlay?['playNavigationEndpoint']?['watchEndpoint'];
                
                final videoId = watchEndpoint?['videoId']?.toString();
                if (videoId == null || videoId.isEmpty) continue;
                
                final s = Song(
                  id: videoId,
                  title: titleText,
                  artist: parsedInfo.subtitle,
                  album: 'YouTube Music',
                  thumbnailUrl: thumb,
                  duration: 0,
                  source: 'youtube'
                );
                    songs.add(s);
                    mixedItems.add(s);
              }
            }
            if (songs.isNotEmpty || playlists.isNotEmpty) {
               sections.add(MusicRecommendationSection(title: title, songs: songs, playlists: playlists, items: mixedItems));
            }
          }
        }
        }
        
        // --- HOME FEED CONTINUATION (PAGINATION) ---
        // The first browse response only returns 3-4 sections. YouTube Music uses
        // continuation tokens to load more sections as the user scrolls down.
        // We fetch up to 7 continuation pages ahead of time to create a full, rich home feed.
        String? nextToken = _extractContinuationToken(data);
        int pages = 1;
        
        while (nextToken != null && pages < 8) {
          // InnerTube pagination sends the continuation token in the POST JSON body
          final nextBody = {
            'context': body['context'],
            'continuation': nextToken,
          };
          
          final nextResponse = await http.post(
            Uri.parse('https://music.youtube.com/youtubei/v1/browse?key=$apiKey&prettyPrint=false'),
            headers: requestHeaders,
            body: jsonEncode(nextBody),
          ).timeout(const Duration(seconds: 15));
          
          if (nextResponse.statusCode != 200) break;
          
          final nextData = jsonDecode(nextResponse.body);
          // In continuation responses, the content is nested in continuationContents -> sectionListContinuation
          final nextSectionList = nextData['continuationContents']?['sectionListContinuation'];
          
          if (nextSectionList != null) {
            final nextContents = nextSectionList['contents'] as List?;
            if (nextContents != null) {
              for (final section in nextContents) {
                // Skip itemSectionRenderer rows to avoid duplicate user library sections
                if (section.containsKey('itemSectionRenderer')) continue;
                
                final carousel = section['musicCarouselShelfRenderer'] ?? section['musicImmersiveCarouselShelfRenderer'] ?? section['musicShelfRenderer'];
                if (carousel == null) continue;
                
                // Extract shelf title
                final header = carousel['header']?['musicCarouselShelfBasicHeaderRenderer'];
                final titleRuns = header?['title']?['runs'] as List?;
                final straplineRuns = header?['strapline']?['runs'] as List?;
                
                String title = titleRuns?.map((r) => r['text']?.toString() ?? '').join('') ?? 'Recommended';
                final strapline = straplineRuns?.map((r) => r['text']?.toString() ?? '').join('') ?? '';
                
                if (strapline.isNotEmpty) {
                  title = strapline + ' ' + title;
                }

                final items = carousel['contents'] as List?;
                if (items == null || items.isEmpty) continue;
                
                final songs = <Song>[];
                final playlists = <MusicPlaylist>[];
                final mixedItems = <dynamic>[];
                
                for (final item in items) {
                  final twoRow = item['musicTwoRowItemRenderer'];
                  final responsive = item['musicResponsiveListItemRenderer'];
                  
                  // Parse card item (album/playlist/song)
                  if (twoRow != null) {
                    final watchEndpoint = twoRow['navigationEndpoint']?['watchEndpoint'];
                    final playlistEndpoint = twoRow['navigationEndpoint']?['watchPlaylistEndpoint'];
                    final browseEndpoint = twoRow['navigationEndpoint']?['browseEndpoint'];
                    
                    final playlistId = playlistEndpoint?['playlistId']?.toString() ??
                               watchEndpoint?['playlistId']?.toString() ??
                               browseEndpoint?['browseId']?.toString();
                    final videoId = watchEndpoint?['videoId']?.toString();
                               
                    if (playlistId == null && videoId == null) continue;
                    
                    final titleText = twoRow['title']?['runs']?[0]?['text']?.toString() ?? 'Unknown';
                    final rawSubtitle = (twoRow['subtitle']?['runs'] as List?)?.map((r) => r['text']?.toString() ?? '').join('') ?? '';
                    final parsedInfo = _parseSubtitleAndCount(rawSubtitle);
                    
                    final thumbnails = twoRow['thumbnailRenderer']?['musicThumbnailRenderer']?['thumbnail']?['thumbnails'] as List?;
                    String thumb = (thumbnails != null && thumbnails.isNotEmpty) ? thumbnails.last['url']?.toString() ?? '' : '';
                    if (thumb.startsWith('//')) thumb = 'https:' + thumb;
                    
                    if (videoId != null && videoId.isNotEmpty && browseEndpoint == null) {
                      final s = Song(
                        id: videoId,
                        title: titleText,
                        artist: parsedInfo.subtitle,
                        album: 'YouTube Music',
                        thumbnailUrl: thumb,
                        duration: 0,
                        source: 'youtube'
                      );
                      songs.add(s);
                      mixedItems.add(s);
                    } else if (playlistId != null && playlistId.isNotEmpty) {
                      String finalId = playlistId.startsWith('VL') ? playlistId.substring(2) : playlistId;
                      final p = MusicPlaylist(
                        id: finalId,
                        title: titleText,
                        owner: parsedInfo.subtitle,
                        thumbnailUrl: thumb,
                        itemCount: parsedInfo.count,
                        source: 'youtube'
                      );
                      playlists.add(p);
                      mixedItems.add(p);
                    }
                  // Parse row item (song)
                  } else if (responsive != null) {
                      final flexColumns = responsive['flexColumns'] as List?;
                      if (flexColumns == null || flexColumns.isEmpty) continue;
                      
                      final titleRuns = (flexColumns[0]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'] as List?);
                      final titleText = titleRuns?[0]?['text']?.toString() ?? 'Unknown';
                      
                      final subtitleRuns = (flexColumns.length > 1) 
                          ? (flexColumns[1]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'] as List?)
                          : null;
                      final rawSubtitle = subtitleRuns?.map((r) => r['text']?.toString() ?? '').join('') ?? '';
                      final parsedInfo = _parseSubtitleAndCount(rawSubtitle);
                      
                      final thumbnails = responsive['thumbnail']?['musicThumbnailRenderer']?['thumbnail']?['thumbnails'] as List?;
                      String thumb = (thumbnails != null && thumbnails.isNotEmpty) ? thumbnails.last['url']?.toString() ?? '' : '';
                      if (thumb.startsWith('//')) thumb = 'https:' + thumb;
                      
                      final overlay = responsive['overlay']?['musicItemThumbnailOverlayRenderer']?['content']?['musicPlayButtonRenderer'];
                      final watchEndpoint = overlay?['playNavigationEndpoint']?['watchEndpoint'];
                      
                      final videoId = watchEndpoint?['videoId']?.toString();
                      if (videoId == null || videoId.isEmpty) continue;
                      
                      final s = Song(id: videoId, title: titleText, artist: parsedInfo.subtitle, album: 'YouTube Music', thumbnailUrl: thumb, duration: 0, source: 'youtube');
                      songs.add(s);
                      mixedItems.add(s);
                    }
                }
                if (songs.isNotEmpty || playlists.isNotEmpty) {
                   sections.add(MusicRecommendationSection(title: title, songs: songs, playlists: playlists, items: mixedItems));
                }
              }
            }
          }
          // Extract the continuation token for the next page
          nextToken = _extractContinuationToken(nextData);
          pages++;
        }
      }
    } catch (e) {
      debugPrint('Error fetching home feed: $e');
    }
    return HomeFeedData(chips: chips, sections: sections);
  }

  /// General-purpose method to browse any YouTube Music container and fetch all its songs.
  ///
  /// What it does:
  /// Given a YouTube Music [browseId] (such as `'VLLM'` for Liked Music or `'VLPL...'` for
  /// a playlist), this method sends an authenticated browse request to InnerTube, parses
  /// the initial list of songs, and repeatedly follows continuation tokens to fetch the
  /// entire tracklist (up to 5,000 songs or 80 pages).
  ///
  /// Parameters:
  /// - [headers]: User authentication headers containing cookies.
  /// - [browseId]: The YouTube Music browse identifier (e.g., `'VLLM'`, `'VL<playlistId>'`).
  /// - [albumName]: The display name for the album/collection assigned to parsed tracks.
  /// - [allowVideoFallback]: Whether to also parse generic video renderers if music renderers are missing.
  ///
  /// Returns:
  /// - A [Future<List<Song>>] of all fetched and parsed songs.
  Future<List<Song>> _fetchMusicBrowse(
    Map<String, String> headers,
    String browseId,
    String albumName, {
    bool allowVideoFallback = true,
  }) async {
    final allSongs = <Song>[];
    String? continuationToken;

    try {
      // Step 1: Ensure the InnerTube client configuration is initialized
      final yt = ytm.YTMusic();
      if (!yt.hasInitialized) {
        await yt
            .initialize(gl: 'US', hl: 'en')
            .timeout(const Duration(seconds: 8))
            .catchError((_) => yt);
      }
      final apiKey = yt.config['INNERTUBE_API_KEY'] ??
          'AIzaSyC1nBR9Gs1m4Hnbp6Ur0qa9Ta1IO9oPras';
      final clientName = yt.config['INNERTUBE_CONTEXT_CLIENT_NAME'] ?? 'WEB_REMIX';
      final clientVersion = yt.config['INNERTUBE_CLIENT_VERSION'] ?? '1.20240610.01.00';
      
      final requestHeaders = _buildInnerTubeHeaders(headers);

      // Initial request body: contains client context and the target browseId
      final body = {
        'context': {
          'client': {
            'clientName': clientName,
            'clientVersion': clientVersion,
            'hl': 'en',
            'gl': 'US',
            'timeZone': 'UTC',
          }
        },
        'browseId': browseId,
      };

      // Step 2: Request the first page of songs
      final uri = Uri.parse(
          'https://music.youtube.com/youtubei/v1/browse?key=$apiKey&prettyPrint=false');
      var response = await http
          .post(
            uri,
            headers: requestHeaders,
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        // Parse songs from the first response page
        allSongs.addAll(_parseYoutubeMusicItems(
          data,
          album: albumName,
          allowVideoFallback: allowVideoFallback,
        ));
        // Check if there is a continuation token for fetching the next page
        final bool isLikedMusic = browseId == 'VLLM' || browseId == 'VLVLLM' || browseId == 'LM';
        continuationToken = _extractContinuationToken(data, isPlaylist: !isLikedMusic);
        debugPrint(
            'YT Browse ($browseId): First page fetched ${allSongs.length} songs, continuation: ${continuationToken != null}');
      } else {
        debugPrint(
            'YT Browse ($browseId) failed with status: ${response.statusCode}, body: ${response.body}');
      }

      // Step 3: Continuation Loop (Pagination)
      // YouTube Music handles pagination by passing a continuation token in the JSON body,
      // NOT in the URL query string. The request must NOT include browseId.
      int pages = 1;
      final seenContinuations = <String>{}; // Set prevents looping on identical tokens
      while (continuationToken != null &&
          seenContinuations.add(continuationToken) &&
          pages < 80 && // Cap at 80 pages to prevent infinite requests
          allSongs.length < 5000) { // Cap at 5,000 songs

        final contUrl = 'https://music.youtube.com/youtubei/v1/browse?key=$apiKey&prettyPrint=false';

        // Body sends only context and the continuation token (no browseId)
        final contBody = {
          'context': body['context'],
          'continuation': continuationToken,
        };

        // Brief delay between page requests to avoid rate limits
        await Future.delayed(const Duration(milliseconds: 300));

        response = await http
            .post(
              Uri.parse(contUrl),
              headers: requestHeaders,
              body: jsonEncode(contBody),
            )
            .timeout(const Duration(seconds: 20));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final newSongs = _parseYoutubeMusicItems(
            data,
            album: albumName,
            allowVideoFallback: allowVideoFallback,
          );
          allSongs.addAll(newSongs);
          final bool isLikedMusic = browseId == 'VLLM' || browseId == 'VLVLLM' || browseId == 'LM';
          continuationToken = _extractContinuationToken(data, isPlaylist: !isLikedMusic);
          pages++;
          debugPrint(
              'YT Browse ($browseId): Page $pages fetched ${newSongs.length} songs, total: ${allSongs.length}, hasMore: ${continuationToken != null}');
        } else {
          debugPrint(
              'YT Browse ($browseId): Page $pages failed with status ${response.statusCode}');
          break;
        }
      }
      debugPrint(
          'YT Browse ($browseId): Complete - fetched ${allSongs.length} songs across $pages pages');
    } catch (e) {
      debugPrint('YT _fetchMusicBrowse error for $browseId: $e');
    }
    return allSongs;
  }

  /// Safely extracts the next continuation token from a YouTube Music response.
  ///
  /// What it does:
  /// Navigates YouTube Music's deeply nested JSON structures to find the pagination token
  /// needed to fetch the next batch of items. YouTube uses several different keys for tokens
  /// (`continuationCommand.token`, `nextContinuationData.continuation`, etc.).
  ///
  /// Parameters:
  /// - [data]: The decoded JSON Map or List from YouTube's response.
  /// - [isPlaylist]: When `true`, restricts the search strictly to the playlist's own shelf.
  ///   CRITICAL: At the bottom of playlist pages, YouTube includes a "Suggested songs" shelf
  ///   with its own continuation token. If we search globally, we might grab the suggestion token
  ///   and get trapped in an endless loop fetching songs that are not in the user's playlist!
  ///
  /// Returns:
  /// - A [String] token if a valid continuation exists, or `null` if we reached the end.
  String? _extractContinuationToken(dynamic data, {bool isPlaylist = false}) {
    String? token;

    // Recursive helper to traverse nodes looking for continuation token keys
    void find(dynamic node) {
      if (token != null || node == null) return;
      if (node is Map) {
        // Skip subtrees that contain irrelevant or infinite tokens
        if (node.containsKey('musicBottomActionRenderer') ||
            node.containsKey('automixPreviewVideoRenderer') ||
            node.containsKey('chipCloudRenderer') ||
            node.containsKey('chipCloudChipRenderer')) {
          return;
        }
        
        // For playlists, skip itemSectionRenderer to avoid finding recommendation tokens
        if (isPlaylist && node.containsKey('itemSectionRenderer')) {
          return;
        }

        // Check the 3 main formats YouTube uses for continuation tokens
        final t = node['continuationCommand']?['token'] ?? 
                  node['nextContinuationData']?['continuation'] ??
                  node['reloadContinuationData']?['continuation'];
                  
        if (t is String && t.length > 8) {
          token = t;
          return;
        }
        
        node.values.forEach(find);
      } else if (node is List) {
        node.forEach(find);
      }
    }

    // For playlists: first search ONLY inside the specific playlist shelf
    try {
      final onResponseReceived = data['onResponseReceivedActions'] as List?;
      final appendAction = onResponseReceived?.isNotEmpty == true ? onResponseReceived![0]['appendContinuationItemsAction'] : null;
      final continuationItems = appendAction?['continuationItems'] as List?;

      final shelf = data['contents']?['singleColumnBrowseResultsRenderer']?['tabs']?[0]?['tabRenderer']?['content']?['sectionListRenderer']?['contents']?[0]?['musicPlaylistShelfRenderer'] ??
                    data['contents']?['singleColumnBrowseResultsRenderer']?['tabs']?[0]?['tabRenderer']?['content']?['sectionListRenderer']?['contents']?[0]?['musicShelfRenderer'] ??
                    data['contents']?['twoColumnBrowseResultsRenderer']?['secondaryContents']?['sectionListRenderer']?['contents']?[0]?['musicPlaylistShelfRenderer'] ??
                    data['continuationContents']?['musicPlaylistShelfContinuation'] ??
                    data['continuationContents']?['musicShelfContinuation'] ??
                    // VLLM (Liked Music) continuation comes back as sectionListContinuation
                    data['continuationContents']?['sectionListContinuation']?['contents']?[0]?['musicPlaylistShelfRenderer'] ??
                    data['continuationContents']?['sectionListContinuation']?['contents']?[0]?['musicShelfRenderer'] ??
                    data['continuationContents']?['sectionListContinuation'];
                    
      if (shelf != null) {
        find(shelf['continuations']);
        if (token != null) return token;
      }
      
      // If we received continuationItems directly (newer 2025 YouTube response format)
      if (continuationItems != null) {
        find(continuationItems);
        if (token != null) return token;
      }
    } catch (_) {}
    
    // For regular playlists, do NOT fall back to a full recursive search because
    // it will pick up the "Suggested songs" token and cause an infinite loop.
    if (isPlaylist) {
      debugPrint('YT Token Extractor: Could not find token in standard shelf paths for strict playlist. Token is $token');
      return token;
    }

    // For non-playlists (like home feed or liked music), safe to search the entire tree
    find(data);
    return token;
  }

  /// Fetches recently played tracks from the user's YouTube account.
  ///
  /// What it does:
  /// Currently returns an empty list `[]` because YouTube cloud history syncing is disabled
  /// in favor of local in-app listening history for improved user privacy and responsiveness.
  ///
  /// Parameters:
  /// - [headers]: User authentication headers.
  /// - [maxPages]: Maximum pages of history (unused).
  ///
  /// Returns:
  /// - A [Future<List<Song>>] which is always empty.
  Future<List<Song>> fetchRecents(Map<String, String> headers, {int maxPages = 3}) async {
    // Disabled YouTube history syncing based on user request.
    // The app will now strictly rely on local in-app listening history.
    return [];
  }

  /// Core parser that extracts a list of [Song] models from YouTube Music's JSON response.
  ///
  /// What it does:
  /// YouTube Music API responses are heavily nested with many different renderer formats.
  /// This method navigates standard browse structures, handles continuation chunks, and has
  /// a recursive greedy fallback to ensure songs are parsed even if YouTube changes its layout.
  /// For each song item, it extracts the title, artist, duration, video ID, setVideoId, and thumbnail.
  ///
  /// Parameters:
  /// - [data]: Raw decoded JSON Map from YouTube Music.
  /// - [album]: Default album name to assign to parsed songs (e.g., "Liked Music" or playlist title).
  /// - [allowVideoFallback]: Whether to parse generic YouTube video cards if music renderers are absent.
  ///
  /// Returns:
  /// - A [List<Song>] of all successfully parsed and validated songs.
  List<Song> _parseYoutubeMusicItems(
    Map<String, dynamic> data, {
    required String album,
    bool allowVideoFallback = true,
  }) {
    final songs = <Song>[];
    try {
      debugPrint('YT Parser: Starting parse for $album');

      // --- STAGE 1: LOCATE SONG ITEMS USING STANDARD JSON PATHS ---
      // YouTube Music responses can be structured in several ways depending on whether
      // it is an initial page load, a continuation, or a new 2025 API response.
      final onResponseReceived = data['onResponseReceivedActions'] as List?;
      final appendAction = onResponseReceived?.isNotEmpty == true ? onResponseReceived![0]['appendContinuationItemsAction'] : null;
      final continuationItems = appendAction?['continuationItems'] as List?;

      // Check standard tabs, section lists, shelf renderers, and continuation containers
      final standardContents = data['contents']
                      ?['singleColumnBrowseResultsRenderer']?['tabs']?[0]
                  ?['tabRenderer']?['content']?['sectionListRenderer']
              ?['contents'] ??
          data['contents']?['sectionListRenderer']?['contents'] ??
          data['contents']?['singleColumnBrowseResultsRenderer']?['tabs']?[0]
                  ?['tabRenderer']?['content']?['musicPlaylistShelfRenderer']
              ?['contents'] ??
          data['contents']?['musicPlaylistShelfRenderer']?['contents'] ??
          data['continuationContents']?['musicPlaylistShelfContinuation']
              ?['contents'] ??
          data['continuationContents']?['musicShelfContinuation']
              ?['contents'] ??
          data['continuationContents']?['sectionListContinuation']?['contents'] ??
          continuationItems;

      List<dynamic> itemsToProcess = [];
      if (standardContents is List) {
        for (final section in standardContents) {
          final shelf = section['musicShelfRenderer'] ??
              section['musicPlaylistShelfRenderer'] ??
              (section.containsKey('musicResponsiveListItemRenderer')
                  ? {
                      'contents': [section]
                    }
                  : null);

          final items = shelf?['contents'] as List?;
          if (items != null) {
            itemsToProcess.addAll(items);
          } else if (section['musicResponsiveListItemRenderer'] != null) {
            itemsToProcess.add(section);
          }
        }
      }

      // Check continuationItems if standardContents list was empty
      if (itemsToProcess.isEmpty) {
        final continuationItems =
            _findNodesRecursive(data, 'continuationItems');
        for (final group in continuationItems) {
          if (group is List) {
            itemsToProcess.addAll(group);
          }
        }
      }

      // --- STAGE 2: GREEDY FALLBACK ---
      // If YouTube changed the container structure and standard paths returned nothing,
      // recursively search the entire JSON tree for music item renderers.
      if (itemsToProcess.isEmpty) {
        debugPrint(
            'YT Parser: Standard paths empty for $album. Entering greedy mode...');
        final res1 =
            _findNodesRecursive(data, 'musicResponsiveListItemRenderer');
        if (res1.isNotEmpty) itemsToProcess.addAll(res1);

        if (allowVideoFallback) {
          final res2 = _findNodesRecursive(data, 'playlistVideoRenderer');
          if (res2.isNotEmpty) itemsToProcess.addAll(res2);
        }
      }

      // --- STAGE 3: EXTRACT SONG DETAILS FROM EACH ITEM ---
      for (var item in itemsToProcess) {
        if (item is! Map) continue;

        // An item can be wrapped in musicResponsiveListItemRenderer or playlistVideoRenderer
        Map? track = item['musicResponsiveListItemRenderer'] ??
            item['playlistVideoRenderer'] ??
            item;

        if (track == null) continue;

        // --- TITLE EXTRACTION ---
        // In responsive list items, Column 0 holds the song title
        final flexColumns = track['flexColumns'] as List?;
        dynamic titleRun;
        if (flexColumns != null && flexColumns.isNotEmpty) {
          final firstCol = flexColumns[0] as Map?;
          titleRun = firstCol?['musicResponsiveListItemFlexColumnRenderer']
              ?['text']?['runs']?[0];
        } else if (track['title'] != null && track['title']['runs'] != null) {
          final titleRuns = track['title']['runs'] as List;
          titleRun = titleRuns.isNotEmpty ? titleRuns[0] : null;
        }

        String title = 'Unknown';
        if (titleRun != null && titleRun['text'] != null) {
          title = titleRun['text'];
        } else if (track['title'] != null &&
            track['title']['simpleText'] != null) {
          title = track['title']['simpleText'];
        }

        // --- VIDEO ID & SET VIDEO ID EXTRACTION ---
        // videoId: The unique YouTube ID for the audio/video track (e.g., 'dQw4w9WgXcQ')
        // setVideoId: Unique identifier of THIS specific song instance within a playlist.
        //             Required when deleting a song from a playlist!
        String? videoId;
        String? setVideoId;
        if (track['playlistItemData'] != null &&
            track['playlistItemData']['videoId'] != null) {
          videoId = track['playlistItemData']['videoId'];
          setVideoId = track['playlistItemData']['setVideoId'];
        } else if (track['videoId'] != null) {
          videoId = track['videoId'].toString();
          setVideoId = track['setVideoId']?.toString();
        } else if (track['navigationEndpoint'] != null) {
          if (track['navigationEndpoint']['watchEndpoint'] != null) {
            videoId = track['navigationEndpoint']['watchEndpoint']['videoId'];
          } else if (track['navigationEndpoint']['watchPodcastEndpoint'] != null) {
            videoId = track['navigationEndpoint']['watchPodcastEndpoint']['videoId'];
          }
        }
        
        // Fallback: check navigationEndpoint on the title run itself
        if (videoId == null && titleRun != null && titleRun['navigationEndpoint'] != null) {
          if (titleRun['navigationEndpoint']['watchEndpoint'] != null) {
            videoId = titleRun['navigationEndpoint']['watchEndpoint']['videoId'];
          } else if (titleRun['navigationEndpoint']['watchPodcastEndpoint'] != null) {
            videoId = titleRun['navigationEndpoint']['watchPodcastEndpoint']['videoId'];
          }
        }

        // Skip any item that does not have a playable videoId
        if (videoId == null) continue;

        String artist = 'YouTube Music';
        int durationSecs = 0;

        // --- ARTIST & DURATION EXTRACTION FROM FLEX COLUMNS ---
        // Column 0 is the title. Columns 1 and above contain metadata runs.
        // A run is a clickable text segment (artist name, album, view count, etc.).
        if (flexColumns != null) {
          for (var i = 1; i < flexColumns.length; i++) {
            final col = flexColumns[i] as Map?;
            final runs = col?['musicResponsiveListItemFlexColumnRenderer']
                ?['text']?['runs'] as List?;
            if (runs == null) continue;

            for (final run in runs) {
              if (run is! Map) continue;
              final text = run['text']?.toString() ?? '';

              // Artist detection: A run is the artist if its browseEndpoint points to
              // a YouTube channel ('UC...') or library artist ('FEmusic_library_artist')
              if (artist == 'YouTube Music' &&
                  run['navigationEndpoint'] != null) {
                final browseId = run['navigationEndpoint']['browseEndpoint']
                            ?['browseId']
                        ?.toString() ??
                    '';
                if (browseId.startsWith('UC') ||
                    browseId.startsWith('FEmusic_library_artist')) {
                  artist = text;
                }
              }

              // Duration detection: Match text patterns like "3:45" (M:SS) or "1:05:30" (H:MM:SS)
              if (durationSecs == 0) {
                final match = RegExp(r'^(\d{1,2}:\d{2}(?::\d{2})?)$')
                    .firstMatch(text.trim());
                if (match != null) {
                  durationSecs = _parseDuration(match.group(1)!);
                }
              }
            }
          }
        }

        // --- DURATION FROM FIXED COLUMNS ---
        // Some YouTube Music versions place the timestamp in fixedColumns instead
        final fixedColumns = track['fixedColumns'] as List?;
        if (fixedColumns != null && durationSecs == 0) {
          for (final col in fixedColumns) {
            final runs = col?['musicResponsiveListItemFixedColumnRenderer']
                ?['text']?['runs'] as List?;
            if (runs != null) {
              for (final run in runs) {
                final text = run['text']?.toString() ?? '';
                final match = RegExp(r'^(\d{1,2}:\d{2}(?::\d{2})?)$')
                    .firstMatch(text.trim());
                if (match != null) {
                  durationSecs = _parseDuration(match.group(1)!);
                }
              }
            }
          }
        }

        // --- FALLBACK FOR PLAYLIST VIDEO RENDERER ---
        // Used when YouTube serves regular video items rather than music items
        if (durationSecs == 0) {
          if (track['shortBylineText'] != null &&
              track['shortBylineText']['runs'] != null) {
            final runs = track['shortBylineText']['runs'] as List;
            if (runs.isNotEmpty && artist == 'YouTube Music') {
              artist = runs[0]['text'] ?? 'YouTube Music';
            }
          }
          final durationText = track['lengthText'] != null
              ? track['lengthText']['simpleText']
              : null;
          if (durationText != null) durationSecs = _parseDuration(durationText);
        }

        // --- THUMBNAIL EXTRACTION ---
        // Thumbnails are listed in order of increasing size; we pick the last one for best resolution
        final thumbData = track['thumbnail'] as Map?;
        String thumbnailUrl = '';
        if (thumbData != null) {
          final musicThumb = thumbData['musicThumbnailRenderer'] as Map?;
          dynamic list;
          if (musicThumb != null) {
            list = musicThumb['thumbnail'] != null
                ? musicThumb['thumbnail']['thumbnails']
                : null;
          } else {
            list = thumbData['thumbnails'];
          }

          if (list is List && list.isNotEmpty) {
            thumbnailUrl = (list.last as Map)['url'] ?? '';
          }
        }

        // Construct the Song data model
        final song = Song(
          id: videoId,
          title: _unescape(title),
          artist: _unescape(artist),
          album: album,
          thumbnailUrl: thumbnailUrl,
          duration: durationSecs,
          source: 'youtube',
          setVideoId: setVideoId,
        );

        // Filter out any non-music noise before adding
        if (_isMusic(song)) {
          songs.add(song);
        }
      }
      debugPrint(
          'YT Parser: Successfully parsed ${songs.length} songs for $album');
    } catch (e, stack) {
      debugPrint('Error parsing YT Music items for $album: $e');
      debugPrint(stack.toString());
    }
    return songs;
  }

  /// Recursively walks a JSON tree (nested Maps and Lists) to find all nodes with a given key.
  ///
  /// What it does:
  /// YouTube responses are deeply and unpredictably nested. When standard paths fail,
  /// this utility performs a depth-first search across all maps and arrays to gather
  /// every instance of [targetKey] (e.g., `'musicResponsiveListItemRenderer'`).
  ///
  /// Parameters:
  /// - [root]: The root JSON Map or List to search within.
  /// - [targetKey]: The exact key string to collect.
  ///
  /// Returns:
  /// - A [List<dynamic>] containing all values associated with [targetKey] across the entire tree.
  List<dynamic> _findNodesRecursive(dynamic root, String targetKey) {
    final results = [];
    if (root is Map) {
      if (root.containsKey(targetKey)) {
        results.add(root[targetKey]);
      }
      for (final value in root.values) {
        results.addAll(_findNodesRecursive(value, targetKey));
      }
    } else if (root is List) {
      for (final element in root) {
        results.addAll(_findNodesRecursive(element, targetKey));
      }
    }
    return results;
  }

  /// Determines whether a song parsed from YouTube Music is valid music.
  ///
  /// What it does:
  /// Since songs are fetched directly from dedicated YouTube Music endpoints (such as
  /// `FEmusic_home` and `VLLM`), YouTube has already curated them as music.
  /// We avoid aggressive title or duration filtering here so that short tracks (e.g.,
  /// intro tracks, interludes, or punk songs under 60 seconds) are never accidentally discarded.
  ///
  /// Parameters:
  /// - [song]: The candidate [Song] object.
  ///
  /// Returns:
  /// - [bool]: Always `true` for items originating from YouTube Music endpoints.
  bool _isMusic(Song song) {
    // We now fetch exclusively from YouTube Music API endpoints (e.g., FEmusic_home, VLLM),
    // which already classifies and filters for music content.
    // Removing strict duration and title blacklists prevents dropping legitimate
    // short songs (e.g., <75s punk songs, interludes, intros) and valid songs with
    // title overlaps (like "tutorial").
    return true;
  }

  /// Heuristic filter used during YouTube Data API v3 fallback to verify if a video is music.
  ///
  /// What it does:
  /// When falling back to the generic YouTube Data API, search and playlist results may
  /// include non-music content (e.g. gaming videos, podcasts, lectures, vlogs).
  /// This method applies multiple layers of filtering:
  /// 1. Runs a strict keyword blacklist check ([_hasBlockedNonMusicSignal]).
  /// 2. If the video belongs to a user's custom playlist, permits it unless it is an obvious lecture.
  /// 3. If the video is from Liked Videos (`LL`), trusts YouTube's official category ID `10` (Music).
  /// 4. For non-category-10 liked videos, requires strong music keywords ('official audio', 'remix', 'vevo')
  ///    and discards long videos (>20 mins) unless tagged as a DJ mix or compilation.
  ///
  /// Parameters:
  /// - [song]: The candidate [Song] to evaluate.
  /// - [categoryId]: YouTube's numeric video category string (Category `'10'` = Music).
  /// - [playlistId]: The playlist ID where the video was found (`'LL'` = Liked Videos).
  ///
  /// Returns:
  /// - [bool]: `true` if the item passes all music validation checks.
  bool _isMusicVideo(Song song, String categoryId, String playlistId) {
    final lowerTitle = song.title.toLowerCase();
    final lowerArtist = song.artist.toLowerCase();
    final isLikedList = playlistId.toUpperCase() == 'LL' ||
        playlistId == 'FEmusic_liked_videos';

    // Step 1: Strict Blacklist Check (rejects vlogs, reactions, podcasts, etc.)
    if (_hasBlockedNonMusicSignal(lowerTitle, lowerArtist)) {
      return false;
    }

    // Step 2: For user-created playlists (not liked videos), only filter out obvious lectures
    if (!isLikedList) {
      final strictNo = ['lecture', 'tutorial', 'course', 'webinar'];
      return !strictNo.any((kw) => lowerTitle.contains(kw));
    }

    // Step 3: For Liked Videos list:
    // If YouTube officially classified it under Category 10 ("Music"), accept it
    if (categoryId == '10') {
      return true;
    }

    // Step 4: If category is unknown or not Category 10 in Liked Videos,
    // apply a blacklist to filter out lifestyle, gaming, and informational videos
    final blacklist = [
      'lecture',
      'tutorial',
      'vlog',
      'unboxing',
      'explained',
      'course',
      'webinar',
      'interview',
      'presentation',
      'how to',
      'reacting to',
      'discussion',
      'lesson',
      'explaining',
      'episode',
      'documentary',
      'commercial',
      'trailer',
      'teaser',
      'daily vlog',
      'funny moments',
      'prank',
      'challenge',
      'reaction',
      'shopping',
      'haul',
      'review',
      'makeup',
      'asmr',
      'commentary',
      'daily life',
      'gaming',
      'walkthrough',
      'gameplay',
      'highlights',
      'top 10',
      'top 5',
      'routine',
      'news',
      'podcast',
      'live reaction',
      'unboxing',
      'comparison',
      'vs',
      'talk show',
      'cooking',
      'recipe',
      'diy',
      'craft',
      'science',
      'history',
      'anime review',
      'movie review',
      'tier list',
      'restoration',
      'woodworking',
      'build',
      'vlogger',
      'blog',
      'vlogging',
      'storytime',
      'facts',
      'theory',
      'secrets'
    ];
    if (blacklist
        .any((kw) => lowerTitle.contains(kw) || lowerArtist.contains(kw))) {
      return false;
    }

    // Step 5: Filter out videos over 20 minutes (1200s) unless explicitly titled as a mix/album
    if (song.duration > 1200) {
      final longAllow = [
        'mix',
        'compilation',
        'lofi',
        'chillhop',
        'playlist',
        'album',
        'set',
        'dj'
      ];
      if (!longAllow.any((w) => lowerTitle.contains(w))) {
        return false;
      }
    }

    // Step 6: Non-category 10 Liked Videos must contain explicit music keywords
    final strongMusicMarkers = [
      'official audio',
      'official video',
      'official music video',
      'remix',
      'lyrics',
      'mv',
      'lofi',
      'chillhop',
      'instrumental',
      'karaoke',
      'acoustic cover',
      'unplugged',
      'music video',
      'full album',
      'song'
    ];
    final artistMusicMarkers = [
      'vevo',
      'music',
      'records',
      'beats',
      'sound',
      'audio',
      'label',
      'productions'
    ];

    final hasStrongMarker =
        strongMusicMarkers.any((m) => lowerTitle.contains(m)) ||
            artistMusicMarkers.any((m) => lowerArtist.contains(m));

    return hasStrongMarker;
  }

  /// Checks whether a title or artist string contains prominent non-music keywords.
  ///
  /// What it does:
  /// Compiles a blacklist of non-music keywords (e.g. 'vlog', 'tutorial', 'gameplay', 'shorts')
  /// into a regex with word boundaries `(?:^|\W)...(?:\W|$)`. This ensures that a title like
  /// "Guitar Tutorial" is blocked, but a song title containing "Tutorial" as a substring isn't
  /// accidentally false-positive matched unless it forms a discrete word.
  ///
  /// Parameters:
  /// - [lowerTitle]: Lowercased video title string.
  /// - [lowerArtist]: Lowercased video owner / channel name string.
  ///
  /// Returns:
  /// - [bool]: `true` if any blocked non-music term is detected.
  bool _hasBlockedNonMusicSignal(String lowerTitle, String lowerArtist) {
    final blacklist = [
      'lecture',
      'tutorial',
      'vlog',
      'unboxing',
      'explained',
      'course',
      'webinar',
      'interview',
      'presentation',
      'how to',
      'reacting to',
      'discussion',
      'lesson',
      'explaining',
      'explains',
      'breakdown',
      'guide',
      'tour',
      'episode',
      'documentary',
      'explanation',
      'gameplay',
      'highlights',
      'stream',
      'playthrough',
      'walkthrough',
      'podcast',
      'full match',
      '#shorts',
      'yt shorts',
      'youtube shorts',
      'shorts',
      'teaser',
      'daily vlog',
      'prank',
      'challenge',
      'reaction',
      'makeup',
      'asmr',
      'commentary',
      'gaming',
      'walkthrough',
      'gameplay',
      'highlights',
      'podcast',
      'live reaction',
      'unboxing',
      'cooking',
      'recipe',
      'diy',
      'craft',
      'science',
      'vlogger',
      'blog',
      'vlogging',
      'facts',
      'theory',
      'news',
      'review',
      'comparison',
      'trailer',
      'movie review',
      'anime review',
      'tier list',
      'storytime',
    ];
    
    // Use word boundaries, but carefully handle words that start with non-word chars like #
    final escaped = blacklist.map(RegExp.escape).join('|');
    final regex = RegExp(r'(?:^|\W)(?:' + escaped + r')(?:\W|$)');
    return regex.hasMatch(lowerTitle) || regex.hasMatch(lowerArtist);
  }

  /// Parses a digital time string ("MM:SS" or "HH:MM:SS") into total seconds.
  ///
  /// What it does:
  /// Splits the string by colons and multiplies each component:
  /// - Two parts ("03:45"): `3 * 60 + 45 = 225 seconds`
  /// - Three parts ("01:15:30"): `1 * 3600 + 15 * 60 + 30 = 4530 seconds`
  ///
  /// Parameters:
  /// - [text]: A formatted duration string.
  ///
  /// Returns:
  /// - [int]: Total duration in seconds, or `0` if the string cannot be parsed.
  int _parseDuration(String text) {
    try {
      final parts = text.split(':').map(int.parse).toList();
      if (parts.length == 2) {
        return parts[0] * 60 + parts[1];
      } else if (parts.length == 3) {
        return parts[0] * 3600 + parts[1] * 60 + parts[2];
      }
    } catch (_) {}
    return 0;
  }

  /// Fetches all playlists saved in the user's YouTube Music library.
  ///
  /// What it does:
  /// Requests the user's playlists library tab (`FEmusic_liked_playlists`), which returns
  /// both user-created custom playlists and third-party playlists the user has saved.
  /// It parses the grid cards, extracts titles, IDs, owners, song counts, and thumbnail images,
  /// and deduplicates the list so only the most complete version of each playlist is returned.
  ///
  /// Parameters:
  /// - [headers]: User authentication headers containing session cookies.
  ///
  /// Returns:
  /// - A [Future<List<MusicPlaylist>>] of user playlists, or an empty list on failure.
  Future<List<MusicPlaylist>> fetchPlaylists(
      Map<String, String> headers) async {
    try {
      // Step 1: Initialize the InnerTube API helper
      final yt = ytm.YTMusic();
      if (!yt.hasInitialized) {
        await yt
            .initialize(gl: 'US', hl: 'en')
            .timeout(const Duration(seconds: 8))
            .catchError((_) => yt);
      }
      final apiKey = yt.config['INNERTUBE_API_KEY'] ??
          'AIzaSyC1nBR9Gs1m4Hnbp6Ur0qa9Ta1IO9oPras';
      final clientName =
          yt.config['INNERTUBE_CONTEXT_CLIENT_NAME'] ?? 'WEB_REMIX';
      final clientVersion =
          yt.config['INNERTUBE_CLIENT_VERSION'] ?? '1.20240610.01.00';

      // Step 2: Request the user's saved playlists
      // 'FEmusic_liked_playlists' is the internal YouTube browse ID for the Library > Playlists tab
      final response = await http
          .post(
            Uri.parse('https://music.youtube.com/youtubei/v1/browse').replace(
              queryParameters: {
                'key': apiKey,
                'prettyPrint': 'false',
              },
            ),
            headers: _buildInnerTubeHeaders(headers),
            body: jsonEncode({
              'context': {
                'client': {
                  'clientName': clientName,
                  'clientVersion': clientVersion,
                  'hl': 'en',
                  'gl': 'US',
                }
              },
              'browseId': 'FEmusic_liked_playlists',
            }),
          )
          .timeout(const Duration(seconds: 20));

      final musicPlaylists = <MusicPlaylist>[];
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        try {
          // --- NAVIGATE LIBRARY PLAYLIST GRID ---
          // Playlists are arranged inside a gridRenderer or musicShelfRenderer
          final contents = data['contents']
                  ?['singleColumnBrowseResultsRenderer']?['tabs']?[0]
              ?['tabRenderer']?['content']?['sectionListRenderer']?['contents'];
          if (contents != null && contents is List) {
            for (final section in contents) {
              final grid = section['gridRenderer'] ?? section['musicShelfRenderer'];
              final items = grid?['items'] ?? grid?['contents'] as List?;
              if (items == null) continue;

              for (final item in items) {
                // Different YouTube Music versions wrap cards in different renderer keys
                final renderer = item['musicTwoColumnItemRenderer'] ??
                    item['musicTwoRowItemRenderer'] ??
                    item['musicResponsiveListItemRenderer'];
                if (renderer == null) continue;

                // Title extraction (handles both runs array and flexColumn formats)
                String title = 'Unknown';
                if (renderer['title']?['runs'] != null) {
                  title = renderer['title']['runs'][0]['text'] ?? 'Unknown';
                } else if (renderer['flexColumns'] != null) {
                  final cols = renderer['flexColumns'] as List?;
                  if (cols != null && cols.isNotEmpty) {
                    title = cols[0]?['musicResponsiveListItemFlexColumnRenderer']
                        ?['text']?['runs']?[0]?['text'] ?? 'Unknown';
                  }
                }

                // Browse ID / Playlist ID extraction
                String? browseId = renderer['navigationEndpoint']
                    ?['browseEndpoint']?['browseId'];
                // Check play button overlay if main navigation endpoint is missing
                browseId ??= renderer['overlay']?['musicItemThumbnailOverlayRenderer']
                      ?['content']?['musicPlayButtonRenderer']
                      ?['playNavigationEndpoint']?['watchPlaylistEndpoint']?['playlistId'];
                if (browseId == null) continue;
                
                // YouTube Music prefixes playlist IDs with 'VL' (View List). Strip it for consistency.
                final playlistId = browseId.startsWith('VL') ? browseId.substring(2) : browseId;
                // Ignore special system playlists (Liked Music, History, auto-generated Radio mixes)
                if (playlistId.isEmpty || playlistId == 'LM' || playlistId == 'SE' || playlistId == 'FEmusic_history' || playlistId.startsWith('RD')) continue;

                // Subtitle extraction (contains owner name and song count, e.g. "Playlist • Sachin • 42 songs")
                String rawSubtitle = '';
                if (renderer['subtitle']?['runs'] != null) {
                  rawSubtitle = (renderer['subtitle']['runs'] as List)
                      .map((r) => r['text']?.toString() ?? '').join('');
                } else if (renderer['flexColumns'] != null) {
                  final cols = renderer['flexColumns'] as List?;
                  if (cols != null && cols.length > 1) {
                    final runs = cols[1]?['musicResponsiveListItemFlexColumnRenderer']
                        ?['text']?['runs'] as List?;
                    rawSubtitle = runs?.map((r) => r['text']?.toString() ?? '').join('') ?? '';
                  }
                }
                
                final parsedInfo = _parseSubtitleAndCount(_unescape(rawSubtitle));

                // Thumbnail image extraction
                final thumbnails = renderer['thumbnail']
                        ?['musicThumbnailRenderer']?['thumbnail']?['thumbnails'] ??
                    renderer['thumbnailRenderer']
                        ?['musicThumbnailRenderer']?['thumbnail']?['thumbnails']
                    as List?;
                String thumb = '';
                if (thumbnails != null && thumbnails is List && thumbnails.isNotEmpty) {
                  thumb = thumbnails.last['url']?.toString() ?? '';
                  if (thumb.startsWith('//')) thumb = 'https:' + thumb;
                }

                musicPlaylists.add(MusicPlaylist(
                  id: playlistId,
                  title: _unescape(title),
                  owner: parsedInfo.subtitle,
                  thumbnailUrl: thumb,
                  itemCount: parsedInfo.count,
                  source: 'youtube',
                ));
              }
            }
          }
        } catch (e) {
          debugPrint('YouTube fetchPlaylists InnerTube parse error: $e');
        }
      }

      // --- PLAYLIST DEDUPLICATION ---
      // YouTube sometimes returns duplicate rows for the same playlist (e.g. from mixed sections).
      // Keep the copy with the highest parsed itemCount.
      final uniquePlaylists = <String, MusicPlaylist>{};
      for (final p in musicPlaylists) {
        final key = p.title.trim().toLowerCase();
        final existing = uniquePlaylists[key];
        if (existing == null || p.itemCount > existing.itemCount) {
          uniquePlaylists[key] = p;
        }
      }
      return uniquePlaylists.values.toList();
    } catch (e) {
      debugPrint('YouTube fetchPlaylists overall failed: $e');
      return [];
    }
  }

  /// Fetches all songs contained within a specific YouTube playlist.
  ///
  /// What it does:
  /// Attempts to fetch the full tracklist using two complementary strategies:
  /// 1. **Primary Strategy (InnerTube API)**: Calls [_fetchMusicBrowse] using `'VL$playlistId'`.
  ///    This is fast, loads accurate music metadata, and handles pagination automatically.
  /// 2. **Fallback Strategy (YouTube Data API v3)**: If InnerTube fails, calls the official
  ///    `playlistItems` endpoint in pages of 50 items. Because `playlistItems` does not
  ///    include song durations or category info, it enriches them in secondary batched calls.
  ///
  /// Parameters:
  /// - [headers]: User authentication headers.
  /// - [playlistId]: The ID of the playlist (with or without 'VL' prefix).
  /// - [album]: Default collection label to attach to songs (defaults to 'YouTube Playlist').
  /// - [maxPages]: Maximum pages to fetch during Data API fallback (default 100).
  ///
  /// Returns:
  /// - A [Future<List<Song>>] of songs, filtering out any deleted during the current session.
  Future<List<Song>> fetchPlaylistSongs(
    Map<String, String> headers,
    String playlistId, {
    String album = 'YouTube Playlist',
    int maxPages = 100,
  }) async {
    // --- PRIMARY STRATEGY: INNERTUBE BROWSE ---
    try {
      // In InnerTube, playlists are browsed using the 'VL' (View List) prefix
      final cleanId =
          playlistId.startsWith('VL') ? playlistId : 'VL$playlistId';
      var songs = await _fetchMusicBrowse(headers, cleanId, album);
      // If 'VL...' returns nothing, try without the 'VL' prefix
      if (songs.isEmpty) {
        final noVlId = playlistId.startsWith('VL') ? playlistId.substring(2) : playlistId;
        songs = await _fetchMusicBrowse(headers, noVlId, album);
      }
        if (songs.isNotEmpty) {
          debugPrint('YT _fetchPlaylistSongs: InnerTube fetch successful. Fetched ${songs.length} songs.');
          // Filter out any songs deleted by the user during this app session
          return songs.where((s) => !_deletedPlaylistItems.contains('${playlistId}_${s.id}')).toList();
        }
    } catch (e) {
      debugPrint('YT Music browse fetchPlaylistSongs InnerTube failed: $e. Falling back to Data API...');
    }

    // --- SECONDARY STRATEGY: YOUTUBE DATA API V3 FALLBACK ---
    try {
      final cleanPlaylistId =
          playlistId.startsWith('VL') ? playlistId.substring(2) : playlistId;
      // Fetch playlist items in pages of 50
      final items = await _fetchPagedItems(
        headers,
        'playlistItems',
        {
          'part': 'snippet,contentDetails',
          'playlistId': cleanPlaylistId,
          'maxResults': '50',
        },
        maxPages: maxPages,
      );

      // Map raw API items to Song models (without duration yet)
      final songs = items
          .map((item) {
            final snippet = item['snippet'];
            final videoId = item['contentDetails']?['videoId'];
            if (videoId == null) return null;

            return Song(
              id: videoId,
              title: _unescape(snippet['title']),
              artist: _unescape(
                  snippet['videoOwnerChannelTitle'] ?? snippet['channelTitle']),
              album: album,
              thumbnailUrl: _bestThumbnail(snippet['thumbnails']),
              duration: 0,
              source: 'youtube',
            );
          })
          .whereType<Song>()
          .toList();

      if (songs.isEmpty) return [];

      // --- BATCH DURATION & CATEGORY ENRICHMENT ---
      // Data API playlistItems doesn't provide video duration or categoryId.
      // We must query the 'videos' endpoint in batches of up to 50 IDs at a time.
      final enrichedSongs = <Song>[];
      for (var i = 0; i < songs.length; i += 50) {
        final end = i + 50 > songs.length ? songs.length : i + 50;
        final batch = songs.sublist(i, end);

        try {
          // Request up to 50 video details in a single HTTP call to minimize network requests
          final videoIds = batch.map((s) => s.id).join(',');
          final videoData = await _getJson(headers, 'videos', {
            'part': 'contentDetails,snippet',
            'id': videoIds,
          });

          final videoItems = videoData['items'] as List?;
          final durationMap = <String, int>{};
          final categoryMap = <String, String>{};
          final channelTitleMap = <String, String>{};
          
          // Populate lookup maps for fast association
          if (videoItems != null) {
            for (final v in videoItems) {
              final id = v['id'];
              final durationStr = v['contentDetails']?['duration'] ?? '';
              if (id is String && durationStr.isNotEmpty) {
                // Convert ISO 8601 duration string (e.g., 'PT4M12S') to integer seconds
                durationMap[id] = _parseIso8601Duration(durationStr);
              }
              final categoryId = v['snippet']?['categoryId'] ?? '';
              if (id is String && categoryId.isNotEmpty) {
                categoryMap[id] = categoryId.toString();
              }
              final chanTitle = v['snippet']?['channelTitle'] ?? '';
              if (id is String && chanTitle.isNotEmpty) {
                channelTitleMap[id] = chanTitle;
              }
            }
          }

          // Build enriched Song models with duration and verify music suitability
          for (final s in batch) {
            final dur = durationMap[s.id] ?? 0;
            final catId = categoryMap[s.id] ?? '';
            final chanTitle = channelTitleMap[s.id] ?? s.artist;

            final enriched = Song(
              id: s.id,
              title: s.title,
              artist: chanTitle,
              album: s.album,
              thumbnailUrl: s.thumbnailUrl,
              duration: dur,
              source: s.source,
            );

            // Filter out non-music video items
            if (_isMusicVideo(enriched, catId, playlistId)) {
              enrichedSongs.add(enriched);
            }
          }
        } catch (e) {
          debugPrint('Batch duration enrichment failed: $e');
          // Fallback: keep items that pass basic music filter even if duration call failed
          for (final s in batch) {
            if (_isMusic(s)) enrichedSongs.add(s);
          }
        }
      }

      // Final pass: exclude any songs deleted during the current app session
      return enrichedSongs.where((s) => !_deletedPlaylistItems.contains('${playlistId}_${s.id}')).toList();
    } catch (e) {
      debugPrint('YouTube fetchPlaylistSongs failed: $e');
      return [];
    }
  }

  /// Converts an ISO 8601 duration string into total seconds.
  ///
  /// What it does:
  /// The official YouTube Data API v3 returns video durations formatted according to ISO 8601,
  /// such as `PT3M45S` (3 minutes, 45 seconds) or `PT1H15M30S` (1 hour, 15 minutes, 30 seconds).
  /// This function uses a regex pattern to extract the hours, minutes, and seconds components
  /// and calculates the total duration in seconds.
  ///
  /// Parameters:
  /// - [isoDuration]: Raw ISO 8601 duration string (e.g. `'PT4M20S'`).
  ///
  /// Returns:
  /// - [int]: Total duration in seconds, or `0` if parsing fails.
  int _parseIso8601Duration(String isoDuration) {
    try {
      final regex = RegExp(r'PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?');
      final match = regex.firstMatch(isoDuration);
      if (match != null) {
        final hours = int.parse(match.group(1) ?? '0');
        final minutes = int.parse(match.group(2) ?? '0');
        final seconds = int.parse(match.group(3) ?? '0');
        return hours * 3600 + minutes * 60 + seconds;
      }
    } catch (_) {}
    return 0;
  }

  /// Creates a new private playlist in the user's YouTube Music account.
  ///
  /// What it does:
  /// Sends a playlist creation command to InnerTube. The playlist is created with
  /// `PRIVATE` privacy status so it only appears in the user's personal library.
  ///
  /// Parameters:
  /// - [headers]: User authentication headers with cookies.
  /// - [title]: The display name for the new playlist.
  ///
  /// Returns:
  /// - A [Future<String?>] containing the newly generated playlist ID (e.g. `'PL...'`),
  ///   or `null` if creation failed.
  Future<String?> createPlaylist(
      Map<String, String> headers, String title) async {
    try {
      final requestHeaders = _buildInnerTubeHeaders(headers);
      final body = {
        'context': {
          'client': {
            'clientName': 'WEB_REMIX',
            'clientVersion': '1.20240610.01.00',
          }
        },
        'title': title,
        'description': '',
        'privacyStatus': 'PRIVATE'
      };

      final response = await http
          .post(
            Uri.parse('https://music.youtube.com/youtubei/v1/playlist/create?key=AIzaSyC1nBR9Gs1m4Hnbp6Ur0qa9Ta1IO9oPras&prettyPrint=false'),
            headers: requestHeaders,
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['playlistId'];
      }
    } catch (e) {
      debugPrint('YouTube createPlaylist failed: $e');
    }
    return null;
  }

  /// Permanently deletes a playlist from the user's YouTube Music library.
  ///
  /// What it does:
  /// Calls InnerTube's `playlist/delete` endpoint with the sanitized playlist ID.
  ///
  /// Parameters:
  /// - [headers]: User authentication headers.
  /// - [playlistId]: The ID of the playlist to delete (with or without 'VL' prefix).
  ///
  /// Returns:
  /// - A [Future<bool>] indicating whether the deletion succeeded.
  Future<bool> deletePlaylist(Map<String, String> headers, String playlistId) async {
    try {
      final requestHeaders = _buildInnerTubeHeaders(headers);
      final body = {
        'context': {
          'client': {
            'clientName': 'WEB_REMIX',
            'clientVersion': '1.20240610.01.00',
          }
        },
        // Strip 'VL' prefix if present
        'playlistId': playlistId.startsWith('VL') ? playlistId.substring(2) : playlistId,
      };

      final response = await http.post(
        Uri.parse('https://music.youtube.com/youtubei/v1/playlist/delete?key=AIzaSyC1nBR9Gs1m4Hnbp6Ur0qa9Ta1IO9oPras&prettyPrint=false'),
        headers: requestHeaders,
        body: jsonEncode(body),
      );
      
      if (response.statusCode == 200) {
        // Success responses typically return STATUS_SUCCEEDED or a deletion confirmation command
        return response.body.contains('STATUS_SUCCEEDED') || response.body.contains('handlePlaylistDeletionCommand');
      }
      return false;
    } catch (e) {
      debugPrint('YouTube deletePlaylist failed: $e');
      return false;
    }
  }

  /// Renames an existing YouTube Music playlist.
  ///
  /// What it does:
  /// Sends an `ACTION_SET_PLAYLIST_NAME` edit command to InnerTube's `browse/edit_playlist` endpoint.
  ///
  /// Parameters:
  /// - [headers]: User authentication headers.
  /// - [id]: The ID of the playlist to rename.
  /// - [newTitle]: The new title string for the playlist.
  ///
  /// Returns:
  /// - A [Future<bool>] returning `true` if the title was updated successfully.
  Future<bool> editPlaylist(Map<String, String> headers, String id, String newTitle) async {
    try {
      final requestHeaders = _buildInnerTubeHeaders(headers);
      final body = {
        'context': {
          'client': {
            'clientName': 'WEB_REMIX',
            'clientVersion': '1.20240610.01.00',
          }
        },
        'playlistId': id.startsWith('VL') ? id.substring(2) : id,
        'actions': [
          {
            'action': 'ACTION_SET_PLAYLIST_NAME',
            'playlistName': newTitle
          }
        ]
      };

      final response = await http.post(
        Uri.parse('https://music.youtube.com/youtubei/v1/browse/edit_playlist?key=AIzaSyC1nBR9Gs1m4Hnbp6Ur0qa9Ta1IO9oPras&prettyPrint=false'),
        headers: requestHeaders,
        body: jsonEncode(body),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['status'] == 'STATUS_SUCCEEDED';
      }
      return false;
    } catch (e) {
      debugPrint('YouTube editPlaylist failed: $e');
      return false;
    }
  }

  /// Adds a song to a specified YouTube Music playlist.
  ///
  /// What it does:
  /// Sends an `ACTION_ADD_VIDEO` edit command to InnerTube's `browse/edit_playlist` endpoint.
  ///
  /// Parameters:
  /// - [headers]: User authentication headers.
  /// - [playlistId]: The target playlist ID.
  /// - [videoId]: The YouTube video ID of the song to append.
  ///
  /// Returns:
  /// - A [Future<bool>] returning `true` if the track was successfully added.
  Future<bool> addSongToPlaylist(
    Map<String, String> headers,
    String playlistId,
    String videoId,
  ) async {
    try {
      final requestHeaders = _buildInnerTubeHeaders(headers);
      final body = {
        'context': {
          'client': {
            'clientName': 'WEB_REMIX',
            'clientVersion': '1.20240610.01.00',
          }
        },
        'playlistId': playlistId.startsWith('VL') ? playlistId.substring(2) : playlistId,
        'actions': [
          {
            'action': 'ACTION_ADD_VIDEO',
            'addedVideoId': videoId
          }
        ]
      };

      final response = await http.post(
        Uri.parse('https://music.youtube.com/youtubei/v1/browse/edit_playlist?key=AIzaSyC1nBR9Gs1m4Hnbp6Ur0qa9Ta1IO9oPras&prettyPrint=false'),
        headers: requestHeaders,
        body: jsonEncode(body),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['status'] == 'STATUS_SUCCEEDED';
      }
      return false;
    } catch (e) {
      debugPrint('YouTube addSongToPlaylist failed: $e');
      return false;
    }
  }

  /// Removes a song from a playlist, or unlikes it if the playlist is Liked Music.
  ///
  /// What it does:
  /// Handles two distinct deletion mechanisms depending on the playlist type:
  /// 1. **Liked Music (`LM` / `VLLM`)**: In YouTube Music, "Liked Music" is not a standard
  ///    editable playlist. Removing a song from it requires un-liking the song via [rateSong]
  ///    with rating `'none'`.
  /// 2. **Custom Playlists**: A playlist can contain the exact same song multiple times.
  ///    YouTube requires a unique instance token called [setVideoId] to know which copy
  ///    to delete. If [overrideSetVideoId] is not already known, this method fetches the
  ///    playlist to find the matching `setVideoId`, then issues an `ACTION_REMOVE_VIDEO` command.
  ///
  /// Parameters:
  /// - [headers]: User authentication headers containing cookies.
  /// - [playlistId]: The ID of the playlist (`'LM'`, `'VLLM'`, or a custom playlist ID).
  /// - [videoId]: The YouTube video ID of the track to remove.
  /// - [overrideSetVideoId]: Optional direct instance ID of the video in the playlist.
  ///
  /// Returns:
  /// - A [Future<bool>] returning `true` if removal succeeded.
  Future<bool> removeSongFromPlaylist(
    Map<String, String> headers,
    String playlistId,
    String videoId,
    [String? overrideSetVideoId]
  ) async {
    // --- SPECIAL CASE: REMOVING FROM LIKED MUSIC ---
    if (playlistId == 'LM' || playlistId == 'VLLM') {
      try {
        // Un-like the song on YouTube's servers
        await rateSong(headers, videoId, 'none');
        // Record in session deleted cache so it disappears immediately from UI
        _deletedPlaylistItems.add('LM_$videoId');
        _deletedPlaylistItems.add('VLLM_$videoId');
        return true;
      } catch (e) {
        debugPrint('Failed to remove from Liked Music: $e');
        return false;
      }
    }

    // --- CASE 2: REMOVING FROM A CUSTOM PLAYLIST ---
    try {
      final requestHeaders = _buildInnerTubeHeaders(headers);
      
      // If setVideoId was not provided, fetch the playlist to discover it
      String? setVideoId = overrideSetVideoId;
      if (setVideoId == null) {
        final browseBody = {
          'context': {
            'client': {
              'clientName': 'WEB_REMIX',
              'clientVersion': '1.20240610.01.00',
            }
          },
          'browseId': playlistId.startsWith('VL') ? playlistId : 'VL$playlistId',
        };
        
        final browseResponse = await http.post(
          Uri.parse('https://music.youtube.com/youtubei/v1/browse?key=AIzaSyC1nBR9Gs1m4Hnbp6Ur0qa9Ta1IO9oPras&prettyPrint=false'),
          headers: requestHeaders,
          body: jsonEncode(browseBody),
        );
        
        if (browseResponse.statusCode == 200) {
          final data = jsonDecode(browseResponse.body);
          // Helper to search nodes for a match on videoId and extract its setVideoId
          void findSetVideoId(dynamic node) {
            if (setVideoId != null || node == null) return;
            if (node is Map) {
              if (node['videoId'] == videoId && node.containsKey('setVideoId')) {
                setVideoId = node['setVideoId']?.toString();
                return;
              }
              if (node.containsKey('playlistItemData')) {
                final pid = node['playlistItemData'];
                if (pid is Map && pid['videoId'] == videoId && pid.containsKey('setVideoId')) {
                  setVideoId = pid['setVideoId']?.toString();
                  return;
                }
              }
              node.values.forEach(findSetVideoId);
            } else if (node is List) {
              node.forEach(findSetVideoId);
            }
          }
          findSetVideoId(data);
        }
      }
      
      // Construct the remove action payload
      final action = <String, String>{};
      if (setVideoId != null && setVideoId!.isNotEmpty) {
        // Preferred: remove by specific playlist entry instance ID
        action['action'] = 'ACTION_REMOVE_VIDEO';
        action['setVideoId'] = setVideoId!;
      } else {
        // Fallback: remove by generic video ID
        action['action'] = 'ACTION_REMOVE_VIDEO_BY_VIDEO_ID';
        action['removedVideoId'] = videoId;
      }

      final editBody = {
        'context': {
          'client': {
            'clientName': 'WEB_REMIX',
            'clientVersion': '1.20240610.01.00',
          }
        },
        'playlistId': playlistId.startsWith('VL') ? playlistId.substring(2) : playlistId,
        'actions': [action]
      };

      // Send edit request to InnerTube
      final response = await http.post(
        Uri.parse('https://music.youtube.com/youtubei/v1/browse/edit_playlist?key=AIzaSyC1nBR9Gs1m4Hnbp6Ur0qa9Ta1IO9oPras&prettyPrint=false'),
        headers: requestHeaders,
        body: jsonEncode(editBody),
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['status'] == 'STATUS_SUCCEEDED') {
          // Track deleted item locally so it is immediately filtered out of cached responses
          _deletedPlaylistItems.add('${playlistId}_$videoId');
          return true;
        }
        return false;
      }
      return false;
    } catch (e) {
      debugPrint('YouTube removeSongFromPlaylist failed: $e');
    }
    return false;
  }

  /// Likes, dislikes, or clears rating on a song in YouTube Music.
  ///
  /// What it does:
  /// Updates the user's like/dislike status for a track. It targets YouTube Music's internal
  /// rating endpoints (`like/like`, `like/dislike`, or `like/removelike`) using InnerTube.
  /// If the InnerTube call fails, it automatically falls back to the standard YouTube Data API
  /// `videos/rate` endpoint.
  ///
  /// Parameters:
  /// - [headers]: User authentication headers containing cookies.
  /// - [videoId]: The YouTube video ID of the song.
  /// - [rating]: The desired rating string:
  ///   - `'LIKE'` -> Marks the song as liked (adds to Liked Music).
  ///   - `'DISLIKE'` -> Marks the song as disliked.
  ///   - `'none'` (or any other value) -> Clears rating (removes from Liked Music).
  ///
  /// Returns:
  /// - A [Future<void>].
  Future<void> rateSong(
      Map<String, String> headers, String videoId, String rating) async {
    try {
      debugPrint('YouTube rateSong: Syncing $rating to YouTube InnerTube backend...');
      // Map user rating to the corresponding InnerTube endpoint
      final endpoint = rating.toUpperCase() == 'LIKE' 
          ? 'like/like' 
          : rating.toUpperCase() == 'DISLIKE' ? 'like/dislike' : 'like/removelike';
          
      final yt = ytm.YTMusic();
      if (!yt.hasInitialized) {
        await yt.initialize(gl: 'US', hl: 'en').catchError((_) => yt);
      }
      final apiKey = yt.config['INNERTUBE_API_KEY'] ?? 'AIzaSyC1nBR9Gs1m4Hnbp6Ur0qa9Ta1IO9oPras';
      final clientName = yt.config['INNERTUBE_CONTEXT_CLIENT_NAME'] ?? 'WEB_REMIX';
      final clientVersion = yt.config['INNERTUBE_CLIENT_VERSION'] ?? '1.20240610.01.00';

      // Primary Attempt: InnerTube API
      final response = await http
          .post(
            Uri.parse('https://music.youtube.com/youtubei/v1/$endpoint?key=$apiKey&prettyPrint=false'),
            headers: _buildInnerTubeHeaders(headers),
            body: jsonEncode({
              'context': {
                'client': {
                  'clientName': clientName,
                  'clientVersion': clientVersion,
                  'hl': 'en',
                  'gl': 'US',
                }
              },
              'target': {
                'videoId': videoId
              }
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200 || response.statusCode == 204) {
        debugPrint('YouTube rateSong success: $rating on $videoId (status ${response.statusCode})');
      } else {
        debugPrint('YouTube rateSong failed: status ${response.statusCode}, body: ${response.body}');
        // Fallback: YouTube Data API v3 rate endpoint
        final dataApiRating = rating.toUpperCase() == 'LIKE' ? 'like' : 'none';
        await http.post(
          Uri.parse('${_base}videos/rate?id=$videoId&rating=$dataApiRating'),
          headers: headers,
        ).timeout(const Duration(seconds: 10));
      }
    } catch (e) {
      debugPrint('YouTube rateSong failed: $e');
    }
  }

  /// Searches the user's saved playlists for one matching a specific name.
  ///
  /// What it does:
  /// Fetches all playlists and performs a case-insensitive, whitespace-trimmed comparison.
  ///
  /// Parameters:
  /// - [headers]: User authentication headers.
  /// - [name]: The title to search for (e.g., "Favorites").
  ///
  /// Returns:
  /// - A [Future<MusicPlaylist?>] matching the name, or `null` if not found.
  Future<MusicPlaylist?> findPlaylistByName(
    Map<String, String> headers,
    String name,
  ) async {
    final playlists = await fetchPlaylists(headers);
    for (final p in playlists) {
      if (p.title.trim().toLowerCase() == name.trim().toLowerCase()) {
        return p;
      }
    }
    return null;
  }

  /// Finds an existing playlist by name, or creates it if it doesn't already exist.
  ///
  /// What it does:
  /// Provides an idempotent way to get a playlist. If a playlist with [title] is found,
  /// it is returned immediately. If not found, a new private playlist is created.
  ///
  /// Parameters:
  /// - [headers]: User authentication headers.
  /// - [title]: The desired playlist name.
  ///
  /// Returns:
  /// - A [Future<MusicPlaylist?>] representing the playlist, or `null` if creation failed.
  Future<MusicPlaylist?> ensurePlaylist(
    Map<String, String> headers,
    String title,
  ) async {
    final existing = await findPlaylistByName(headers, title);
    if (existing != null) return existing;

    final id = await createPlaylist(headers, title);
    if (id == null) return null;

    return MusicPlaylist(
      id: id,
      title: title,
      owner: 'Me',
      thumbnailUrl: '',
      itemCount: 0,
      source: 'youtube',
    );
  }

  /// Helper to fetch multiple pages from the official YouTube Data API v3 using page tokens.
  ///
  /// What it does:
  /// Sequentially fetches up to [maxPages] by passing the `nextPageToken` returned
  /// in each response back into the subsequent request query parameters.
  ///
  /// Parameters:
  /// - [headers]: User authentication headers.
  /// - [endpoint]: Data API endpoint name (e.g. `'playlistItems'`, `'videos'`).
  /// - [params]: Query parameters to pass to the endpoint.
  /// - [maxPages]: Upper limit of pages to fetch (defaults to 4).
  ///
  /// Returns:
  /// - A [Future<List<dynamic>>] containing all combined items across all pages.
  Future<List<dynamic>> _fetchPagedItems(
    Map<String, String> headers,
    String endpoint,
    Map<String, String> params, {
    int maxPages = 4,
  }) async {
    final allItems = [];
    String? nextPageToken;

    for (var i = 0; i < maxPages; i++) {
      final queryParams = Map<String, String>.from(params);
      if (nextPageToken != null) queryParams['pageToken'] = nextPageToken;

      try {
        final data = await _getJson(headers, endpoint, queryParams);
        final items = data['items'] as List?;
        if (items != null) allItems.addAll(items);

        nextPageToken = data['nextPageToken'];
        // Stop if there are no more pages or no items returned
        if (nextPageToken == null || items == null || items.isEmpty) break;
      } catch (e) {
        debugPrint('YouTube paged fetch error at page $i: $e');
        break;
      }
    }
    return allItems;
  }

  /// Sends an HTTP GET request to a YouTube Data API v3 endpoint and decodes the JSON.
  ///
  /// What it does:
  /// Appends [params] to the base URL `$_base$endpoint`, performs the GET request with
  /// a 15-second timeout, verifies status 200, and decodes the response body into a Map.
  ///
  /// Parameters:
  /// - [headers]: Authentication headers.
  /// - [endpoint]: The API route to query (e.g. `'videos'`).
  /// - [params]: Key-value query parameters for the request.
  ///
  /// Returns:
  /// - A [Future<Map<String, dynamic>>] with the parsed JSON data.
  ///
  /// Throws:
  /// - [YoutubeAccountException] if the request fails with a non-200 status or invalid JSON.
  Future<Map<String, dynamic>> _getJson(
    Map<String, String> headers,
    String endpoint,
    Map<String, String> params,
  ) async {
    final uri = Uri.parse('$_base$endpoint').replace(queryParameters: params);
    final response = await http
        .get(uri, headers: headers)
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      final truncated = response.body.length > 500
          ? response.body.substring(0, 500)
          : response.body;
      debugPrint(
          'YouTube API $endpoint returned ${response.statusCode}. Body (truncated): $truncated');
      throw YoutubeAccountException(
          'YouTube API error: ${response.statusCode}');
    }
    try {
      return jsonDecode(response.body);
    } catch (e) {
      debugPrint('YouTube API $endpoint returned invalid JSON: $e');
      throw const YoutubeAccountException('Invalid JSON from YouTube API');
    }
  }

  /// Selects the best available thumbnail image URL from YouTube's thumbnails dictionary.
  ///
  /// What it does:
  /// Checks candidate resolutions in order of preference:
  /// 1. `'high'` (hqdefault.jpg - reliable, good resolution, never 404s)
  /// 2. `'medium'` (mqdefault.jpg)
  /// 3. `'standard'` (sddefault.jpg)
  /// 4. `'maxres'` (maxresdefault.jpg - highest resolution, but can 404 if the video is SD)
  /// 5. `'default'` (default.jpg - lowest resolution fallback)
  /// Also ensures the URL has a proper `https:` prefix if protocol-relative.
  ///
  /// Parameters:
  /// - [thumbnails]: A map of thumbnail resolution keys to image metadata objects.
  ///
  /// Returns:
  /// - A [String] containing the image URL, or empty string `''` if none found.
  String _bestThumbnail(Map<String, dynamic>? thumbnails) {
    if (thumbnails == null) return '';
    // Prefer 'high' (hqdefault.jpg) as it never 404s unlike maxres
    final keys = ['high', 'medium', 'standard', 'maxres', 'default'];
    for (final key in keys) {
      if (thumbnails[key] != null) {
        String url = thumbnails[key]['url'];
        if (url.startsWith('//')) url = 'https:' + url;
        return url;
      }
    }
    return '';
  }

  /// Decodes common HTML entity escape codes into readable characters.
  ///
  /// What it does:
  /// YouTube API responses often encode special characters as HTML entities
  /// (e.g. `&amp;` for `&`, `&#039;` for `'`). This method restores them to
  /// normal human-readable characters so song and artist titles display cleanly in the UI.
  ///
  /// Parameters:
  /// - [text]: The raw string containing HTML entities.
  ///
  /// Returns:
  /// - A cleaned [String] with entities decoded.
  String _unescape(String text) {
    return text
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#039;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>');
  }
}

/// Custom exception thrown when a YouTube API call fails or receives invalid data.
class YoutubeAccountException implements Exception {
  final String message;
  const YoutubeAccountException(this.message);
  @override
  String toString() => message;
}

