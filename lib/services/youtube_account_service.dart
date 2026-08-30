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

class YoutubeAccountService {
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

  static const _base = 'https://www.googleapis.com/youtube/v3/';

  Future<AccountLibrary> fetchLibrary(Map<String, String> headers) async {
    debugPrint('YouTubeAccountService: Starting fetchLibrary...');
    List<Song> likedSongs = [];
    List<Song> recentSongs = [];
    List<MusicPlaylist> playlists = [];

    int failCount = 0;

    try {
      // Fetch parts sequentially with short delays to avoid rate limits
      // and ensure we don't hang if one takes too long
      debugPrint('YouTubeAccountService: Fetching Liked Songs...');
      likedSongs = await _fetchLikedSongs(headers)
          .timeout(const Duration(seconds: 150))
          .catchError((e) {
        debugPrint('YouTube _fetchLikedSongs failed: $e');
        failCount++;
        return <Song>[];
      });
      await Future.delayed(const Duration(milliseconds: 300));

      debugPrint('YouTubeAccountService: Fetching Recents...');
      recentSongs = await fetchRecents(headers)
          .timeout(const Duration(seconds: 15))
          .catchError((e) {
        debugPrint('YouTube fetchRecents failed: $e');
        failCount++;
        return <Song>[];
      });
      await Future.delayed(const Duration(milliseconds: 300));

      debugPrint('YouTubeAccountService: Fetching Playlists...');
      playlists = await fetchPlaylists(headers)
          .timeout(const Duration(seconds: 75))
          .catchError((e) {
        debugPrint('YouTube fetchPlaylists failed: $e');
        failCount++;
        return <MusicPlaylist>[];
      });

      if (failCount == 3 ||
          (likedSongs.isEmpty && recentSongs.isEmpty && playlists.isEmpty)) {
        debugPrint(
            'YouTubeAccountService: All fetch operations failed or returned empty.');
        // We don't throw here to avoid breaking the whole app,
        // but we log it heavily.
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

  Future<List<Song>> _fetchLikedSongs(Map<String, String> headers) async {
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
      debugPrint('YT _fetchLikedSongs VLLM failed: ');
      return [];
    }
  }

  Future<HomeFeedData> fetchHomeFeed(Map<String, String> headers) async {
    final sections = <MusicRecommendationSection>[];
    final chips = <String>[];
    try {
      final yt = ytm.YTMusic();
      if (!yt.hasInitialized) {
        await yt.initialize(gl: 'US', hl: 'en').catchError((_) => yt);
      }
      final apiKey = yt.config['INNERTUBE_API_KEY'] ?? 'AIzaSyC1nBR9Gs1m4Hnbp6Ur0qa9Ta1IO9oPras';
      final clientName = yt.config['INNERTUBE_CONTEXT_CLIENT_NAME'] ?? 'WEB_REMIX';
      final clientVersion = yt.config['INNERTUBE_CLIENT_VERSION'] ?? '1.20240610.01.00';
      
      final requestHeaders = _buildInnerTubeHeaders(headers);

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
        'browseId': 'FEmusic_home',
      };

      final response = await http.post(
        Uri.parse('https://music.youtube.com/youtubei/v1/browse?key=$apiKey&prettyPrint=false'),
        headers: requestHeaders,
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final sectionList = data['contents']?['singleColumnBrowseResultsRenderer']?['tabs']?[0]?['tabRenderer']?['content']?['sectionListRenderer'];
        if (sectionList != null) {
          final headerChips = sectionList['header']?['chipCloudRenderer']?['chips'] as List?;
          if (headerChips != null) {
            for (final chip in headerChips) {
              final text = chip['chipCloudChipRenderer']?['text']?['runs']?[0]?['text']?.toString();
              if (text != null && text.isNotEmpty) {
                chips.add(text);
              }
            }
          }

          final contents = sectionList['contents'] as List?;
          if (contents != null) {
            for (final section in contents) {
            final carousel = section['musicCarouselShelfRenderer'];
            if (carousel == null) continue;
            
            final titleObj = carousel['header']?['musicCarouselShelfBasicHeaderRenderer']?['title']?['runs']?[0];
            final title = titleObj?['text']?.toString() ?? 'Recommended';
            
            final items = carousel['contents'] as List?;
            if (items == null || items.isEmpty) continue;
            
            final songs = <Song>[];
            final playlists = <MusicPlaylist>[];
            
            for (final item in items) {
              final twoRow = item['musicTwoRowItemRenderer'];
              final responsive = item['musicResponsiveListItemRenderer'];
              
              if (twoRow != null) {
                final watchEndpoint = twoRow['navigationEndpoint']?['watchEndpoint'];
                final playlistEndpoint = twoRow['navigationEndpoint']?['watchPlaylistEndpoint'];
                final browseEndpoint = twoRow['navigationEndpoint']?['browseEndpoint'];
                

                
                final id = playlistEndpoint?['playlistId']?.toString() ??
                           watchEndpoint?['playlistId']?.toString() ??
                           browseEndpoint?['browseId']?.toString() ??
                           watchEndpoint?['videoId']?.toString();
                           
                if (id == null || id.isEmpty) continue;
                
                final titleText = twoRow['title']?['runs']?[0]?['text']?.toString() ?? 'Unknown';
                final subtitleText = (twoRow['subtitle']?['runs'] as List?)?.map((r) => r['text']?.toString() ?? '').join('') ?? '';
                
                final thumbnails = twoRow['thumbnailRenderer']?['musicThumbnailRenderer']?['thumbnail']?['thumbnails'] as List?;
                final thumb = (thumbnails != null && thumbnails.isNotEmpty) ? thumbnails.last['url']?.toString() ?? '' : '';
                
                // In YouTube Music, twoRowItemRenderer is essentially always a card (album/playlist/artist/mix).
                // We map all of these to MusicPlaylist so they render properly as square horizontal cards.
                String finalId = id;
                if (finalId.startsWith('VL')) finalId = finalId.substring(2);
                
                playlists.add(MusicPlaylist(
                  id: finalId,
                  title: titleText,
                  owner: subtitleText,
                  thumbnailUrl: thumb,
                  itemCount: 0,
                  source: 'youtube'
                ));
              } else if (responsive != null) {
                final flexColumns = responsive['flexColumns'] as List?;
                if (flexColumns == null || flexColumns.isEmpty) continue;
                
                final titleRuns = (flexColumns[0]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'] as List?);
                final titleText = titleRuns?[0]?['text']?.toString() ?? 'Unknown';
                
                final subtitleRuns = (flexColumns.length > 1) 
                    ? (flexColumns[1]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'] as List?)
                    : null;
                final subtitleText = subtitleRuns?.map((r) => r['text']?.toString() ?? '').join('') ?? '';
                
                final thumbnails = responsive['thumbnail']?['musicThumbnailRenderer']?['thumbnail']?['thumbnails'] as List?;
                final thumb = (thumbnails != null && thumbnails.isNotEmpty) ? thumbnails.last['url']?.toString() ?? '' : '';
                
                final overlay = responsive['overlay']?['musicItemThumbnailOverlayRenderer']?['content']?['musicPlayButtonRenderer'];
                final watchEndpoint = overlay?['playNavigationEndpoint']?['watchEndpoint'];
                
                final videoId = watchEndpoint?['videoId']?.toString();
                if (videoId == null || videoId.isEmpty) continue;
                
                songs.add(Song(
                  id: videoId,
                  title: titleText,
                  artist: subtitleText,
                  album: 'YouTube Music',
                  thumbnailUrl: thumb,
                  duration: 0,
                  source: 'youtube'
                ));
              }
            }
            if (songs.isNotEmpty || playlists.isNotEmpty) {
               sections.add(MusicRecommendationSection(title: title, songs: songs, playlists: playlists));
            }
          }
        }
      }
      }
    } catch (e) {
      debugPrint('Error fetching home feed: $e');
    }
    return HomeFeedData(chips: chips, sections: sections);
  }

  Future<List<Song>> _fetchMusicBrowse(
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
      final clientName = yt.config['INNERTUBE_CONTEXT_CLIENT_NAME'] ?? 'WEB_REMIX';
      final clientVersion = yt.config['INNERTUBE_CLIENT_VERSION'] ?? '1.20240610.01.00';
      
      final cookieString = headers['Cookie'] ?? '';

      final requestHeaders = _buildInnerTubeHeaders(headers);

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
        allSongs.addAll(_parseYoutubeMusicItems(
          data,
          album: albumName,
          allowVideoFallback: allowVideoFallback,
        ));
        continuationToken = _extractContinuationToken(data);
        debugPrint(
            'YT Browse ($browseId): First page fetched ${allSongs.length} songs, continuation: ${continuationToken != null}');
      } else {
        debugPrint(
            'YT Browse ($browseId) failed with status: ${response.statusCode}, body: ${response.body}');
      }

      // Continuation loop - keep fetching until no more pages or max reached.
      // YouTube Music browse continuations are sent in the body; keeping them
      // there is important for large liked libraries and private playlists.
      int pages = 1;
      final seenContinuations = <String>{};
      while (continuationToken != null &&
          seenContinuations.add(continuationToken) &&
          pages < 80 &&
          allSongs.length < 5000) {
        final contBody = {
          'context': body['context'],
          'continuation': continuationToken,
        };

        final contUri =
            Uri.parse('https://music.youtube.com/youtubei/v1/browse').replace(
          queryParameters: {
            'key': apiKey,
            'prettyPrint': 'false',
          },
        );
        response = await http
            .post(
              contUri,
              headers: requestHeaders,
              body: jsonEncode(contBody),
            )
            .timeout(const Duration(seconds: 15));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final newSongs = _parseYoutubeMusicItems(
            data,
            album: albumName,
            allowVideoFallback: allowVideoFallback,
          );
          allSongs.addAll(newSongs);
          continuationToken = _extractContinuationToken(data);
          pages++;
          debugPrint(
              'YT Browse ($browseId): Page $pages fetched ${newSongs.length} songs, total: ${allSongs.length}, hasMore: ${continuationToken != null}');
        } else {
          debugPrint(
              'YT Browse ($browseId): Page $pages failed with status ${response.statusCode}');
          break;
        }
      }
      final deduped = _dedupeSongs(allSongs);
      allSongs
        ..clear()
        ..addAll(deduped);
      debugPrint(
          'YT Browse ($browseId): Complete - fetched ${allSongs.length} songs across $pages pages');
    } catch (e) {
      debugPrint('YT _fetchMusicBrowse error for $browseId: $e');
    }
    return allSongs;
  }


  String? _extractContinuationToken(dynamic data) {
    try {
      final directLists = [
        data['continuationContents']?['musicPlaylistShelfContinuation']
            ?['continuations'],
        data['continuationContents']?['musicShelfContinuation']
            ?['continuations'],
        data['continuationContents']?['sectionListContinuation']
            ?['continuations'],
      ];
      for (final list in directLists) {
        if (list is! List) continue;
        for (final item in list) {
          if (item is! Map) continue;
          final token = item['nextContinuationData']?['continuation'] ??
              item['reloadContinuationData']?['continuation'] ??
              item['continuationCommand']?['token'];
          if (token is String && token.length > 8) return token;
        }
      }

      final nodes = _findNodesRecursive(data, 'continuationItemRenderer');
      for (final node in nodes) {
        if (node is Map) {
          final token = node['continuationEndpoint']?['continuationCommand']
                  ?['token'] ??
              node['continuationEndpoint']?['token'];
          if (token is String && token.length > 8) return token;
        }
      }

      final continuationCommands =
          _findNodesRecursive(data, 'continuationCommand');
      for (final command in continuationCommands) {
        if (command is Map) {
          final token = command['token'];
          if (token is String && token.length > 8) return token;
        }
      }

      final endpointTokens = _findNodesRecursive(data, 'nextContinuationData');
      for (final endpoint in endpointTokens) {
        if (endpoint is Map) {
          final token = endpoint['continuation'];
          if (token is String && token.length > 8) return token;
        }
      }

      final conts = _findNodesRecursive(data, 'continuation');
      for (final c in conts) {
        if (c is String && c.length > 8) return c;
      }
    } catch (_) {}
    return null;
  }

  Future<List<Song>> fetchRecents(Map<String, String> headers,
      {int maxPages = 3}) async {
    try {
      final Map<String, String> requestHeaders = {
        ...headers,
        'Content-Type': 'application/json',
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36',
        'X-Youtube-Client-Name': '67',
        'X-Youtube-Client-Version': '1.20240610.01.00',
        'Accept': '*/*',
        'Accept-Language': 'en-US,en;q=0.9',
      };

      final response = await http
          .post(
            Uri.parse(
                'https://music.youtube.com/youtubei/v1/browse?prettyPrint=false'),
            headers: requestHeaders,
            body: jsonEncode({
              'context': {
                'client': {
                  'clientName': 'WEB_REMIX',
                  'clientVersion': '1.20240610.01.00',
                  'hl': 'en',
                  'gl': 'US',
                }
              },
              'browseId': 'FEmusic_history',
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) return [];
      final data = jsonDecode(response.body);
      return _parseYoutubeMusicItems(data, album: 'Recent Music');
    } catch (e) {
      debugPrint('YouTube fetchRecents (Music History) failed: $e');
      return [];
    }
  }

  List<Song> _parseYoutubeMusicItems(
    Map<String, dynamic> data, {
    required String album,
    bool allowVideoFallback = true,
  }) {
    final songs = <Song>[];
    try {
      debugPrint('YT Parser: Starting parse for $album');

      // 1. Try standard paths first (including continuation contents)
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
          data['continuationContents']?['sectionListContinuation']?['contents'];

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

      if (itemsToProcess.isEmpty) {
        final continuationItems =
            _findNodesRecursive(data, 'continuationItems');
        for (final group in continuationItems) {
          if (group is List) {
            itemsToProcess.addAll(group);
          }
        }
      }

      // 2. Greedy Fallback: If standard paths failed, recursively find all music items
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

      for (var item in itemsToProcess) {
        if (item is! Map) continue;

        Map? track = item['musicResponsiveListItemRenderer'] ??
            item['playlistVideoRenderer'] ??
            item;

        if (track == null) continue;

        // Title extraction
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

        // Video ID extraction
        String? videoId;
        if (track['playlistItemData'] != null &&
            track['playlistItemData']['videoId'] != null) {
          videoId = track['playlistItemData']['videoId'];
        } else if (track['videoId'] != null) {
          videoId = track['videoId'].toString();
        } else if (track['navigationEndpoint'] != null &&
            track['navigationEndpoint']['watchEndpoint'] != null) {
          videoId = track['navigationEndpoint']['watchEndpoint']['videoId'];
        } else if (titleRun != null &&
            titleRun['navigationEndpoint'] != null &&
            titleRun['navigationEndpoint']['watchEndpoint'] != null) {
          videoId = titleRun['navigationEndpoint']['watchEndpoint']['videoId'];
        }

        if (videoId == null) continue;

        String artist = 'YouTube Music';
        int durationSecs = 0;

        // Flex Columns - Artist & Duration
        if (flexColumns != null) {
          for (var i = 1; i < flexColumns.length; i++) {
            final col = flexColumns[i] as Map?;
            final runs = col?['musicResponsiveListItemFlexColumnRenderer']
                ?['text']?['runs'] as List?;
            if (runs == null) continue;

            for (final run in runs) {
              if (run is! Map) continue;
              final text = run['text']?.toString() ?? '';

              // Artist detection
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

              // Duration detection (regex for M:SS or H:MM:SS)
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

        // Fixed Columns - Often contains duration
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

        // Fallback for playlistVideoRenderer
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

        final song = Song(
          id: videoId,
          title: _unescape(title),
          artist: _unescape(artist),
          album: album,
          thumbnailUrl: thumbnailUrl,
          duration: durationSecs,
          source: 'youtube',
        );

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

  List<Song> _dedupeSongs(List<Song> songs) {
    final deduped = <String, Song>{};
    for (final song in songs) {
      if (song.id.isEmpty) continue;
      deduped.putIfAbsent('${song.source}:${song.id}', () => song);
    }
    return deduped.values.toList(growable: false);
  }

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

  bool _isMusic(Song song) {
    final lowerTitle = song.title.toLowerCase();
    final lowerArtist = song.artist.toLowerCase();

    if (_hasBlockedNonMusicSignal(lowerTitle, lowerArtist)) {
      return false;
    }


    // 2. Duration filter (shorts under 15 seconds are blocked, except explicitly ringtones)
    if (song.duration > 0 && song.duration < 15) {
      final shortAllow = ['ringtone', 'loop', 'intro', 'outro', 'beat'];
      if (!shortAllow.any((w) => lowerTitle.contains(w))) {
        return false;
      }
    }

    return true;
  }

  bool _isMusicVideo(Song song, String categoryId, String playlistId) {
    final lowerTitle = song.title.toLowerCase();
    final lowerArtist = song.artist.toLowerCase();
    final isLikedList = playlistId.toUpperCase() == 'LL' ||
        playlistId == 'FEmusic_liked_videos';

    // 1. Strict Blacklist Check FIRST (Before category logic)
    if (_hasBlockedNonMusicSignal(lowerTitle, lowerArtist)) {
      return false;
    }

    // 2. Strict Shorts Check (Even if category is 10, block shorts)
    if (song.duration > 0 && song.duration <= 75) {
      final shortAllow = ['ringtone', 'loop', 'intro', 'outro', 'beat', 'interlude'];
      if (!shortAllow.any((w) => lowerTitle.contains(w))) {
        return false; // Block all Shorts <= 75 seconds!
      }
    }

    // 3. For user-created playlists (not liked videos), only filter out obvious non-music lectures/tutorials
    if (!isLikedList) {
      final strictNo = ['lecture', 'tutorial', 'course', 'webinar'];
      return !strictNo.any((kw) => lowerTitle.contains(kw));
    }

    // 4. For Liked Videos list:
    // If it's officially Music category, allow it
    if (categoryId == '10') {
      return true; // Trust YouTube's own Music categorization for Liked Videos.
    }

    // If it's NOT category 10 (or category is unknown) and it's Liked Videos:
    // We apply a strict blacklist to filter out vlogs, explanations, gaming, etc.
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

    // Filter out extremely long non-mix videos (e.g. over 20 minutes)
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

    // Since it's not Category 10, we require a strong music signature to allow it from Liked Videos
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

  Future<List<MusicPlaylist>> fetchPlaylists(
      Map<String, String> headers) async {
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
      final clientName =
          yt.config['INNERTUBE_CONTEXT_CLIENT_NAME'] ?? 'WEB_REMIX';
      final clientVersion =
          yt.config['INNERTUBE_CLIENT_VERSION'] ?? '1.20240610.01.00';

      // First fetch standard YT Music Library playlists
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
          final contents = data['contents']
                  ?['singleColumnBrowseResultsRenderer']?['tabs']?[0]
              ?['tabRenderer']?['content']?['sectionListRenderer']?['contents'];
          if (contents != null && contents is List) {
            for (final section in contents) {
              final grid = section['gridRenderer'];
              final items = grid?['items'] as List?;
              if (items == null) continue;

              for (final item in items) {
                final renderer = item['musicTwoColumnItemRenderer'];
                if (renderer == null) continue;

                final title =
                    renderer['title']?['runs']?[0]?['text'] ?? 'Unknown';
                final browseId = renderer['navigationEndpoint']
                    ?['browseEndpoint']?['browseId'];
                if (browseId == null || !browseId.startsWith('VL')) continue;

                final playlistId = browseId.substring(2); // Remove 'VL' prefix
                final subtitle =
                    renderer['subtitle']?['runs']?[0]?['text'] ?? '';

                final thumbnails = renderer['thumbnail']
                        ?['musicThumbnailRenderer']?['thumbnail']?['thumbnails']
                    as List?;
                String thumb = '';
                if (thumbnails != null && thumbnails.isNotEmpty) {
                  thumb = thumbnails.last['url'];
                }

                musicPlaylists.add(MusicPlaylist(
                  id: playlistId,
                  title: _unescape(title),
                  owner: _unescape(subtitle),
                  thumbnailUrl: thumb,
                  itemCount: 0,
                  source: 'youtube',
                ));
              }
            }
          }
        } catch (_) {}
      }

      List<MusicPlaylist> ytPlaylists = [];
      try {
        final items = await _fetchPagedItems(
          headers,
          'playlists',
          {
            'part': 'snippet,contentDetails,status',
            'mine': 'true',
            'maxResults': '50',
          },
          maxPages: 20,
        );

        ytPlaylists = items.map((item) {
          final snippet = item['snippet'];
          return MusicPlaylist(
            id: item['id'],
            title: _unescape(snippet['title']),
            owner: snippet['channelTitle'],
            thumbnailUrl: _bestThumbnail(snippet['thumbnails']),
            itemCount: item['contentDetails']?['itemCount'] ?? 0,
            source: 'youtube',
          );
        }).toList();
      } catch (e) {
        debugPrint('YouTube fetchPlaylists standard API call failed (possibly quota): $e');
      }

      final combined = [...musicPlaylists, ...ytPlaylists];
      final uniquePlaylists = <String, MusicPlaylist>{};
      for (final p in combined) {
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

  Future<List<Song>> fetchPlaylistSongs(
    Map<String, String> headers,
    String playlistId, {
    String album = 'YouTube Playlist',
    int maxPages = 100,
  }) async {
    try {
      final cleanId =
          playlistId.startsWith('VL') ? playlistId : 'VL$playlistId';
      var songs = await _fetchMusicBrowse(headers, cleanId, album);
      if (songs.isEmpty) {
        final noVlId = playlistId.startsWith('VL') ? playlistId.substring(2) : playlistId;
        songs = await _fetchMusicBrowse(headers, noVlId, album);
      }
      if (songs.isNotEmpty) {
        debugPrint('YT _fetchPlaylistSongs: InnerTube fetch successful. Fetched ${songs.length} songs.');
        return songs;
      }
    } catch (e) {
      debugPrint('YT Music browse fetchPlaylistSongs InnerTube failed: $e. Falling back to Data API...');
    }

    try {
      final cleanPlaylistId =
          playlistId.startsWith('VL') ? playlistId.substring(2) : playlistId;
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

      // Fetch durations in batches of 50 (YouTube API limit)
      final enrichedSongs = <Song>[];
      for (var i = 0; i < songs.length; i += 50) {
        final end = i + 50 > songs.length ? songs.length : i + 50;
        final batch = songs.sublist(i, end);

        try {
          final videoIds = batch.map((s) => s.id).join(',');
          final videoData = await _getJson(headers, 'videos', {
            'part': 'contentDetails,snippet',
            'id': videoIds,
          });

          final videoItems = videoData['items'] as List?;
          final durationMap = <String, int>{};
          final categoryMap = <String, String>{};
          final channelTitleMap = <String, String>{};
          if (videoItems != null) {
            for (final v in videoItems) {
              final id = v['id'];
              final durationStr = v['contentDetails']?['duration'] ?? '';
              if (id is String && durationStr.isNotEmpty) {
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

            if (_isMusicVideo(enriched, catId, playlistId)) {
              enrichedSongs.add(enriched);
            }
          }
        } catch (e) {
          debugPrint('Batch duration enrichment failed: $e');
          // Fallback: add items that pass keyword filter even without duration
          for (final s in batch) {
            if (_isMusic(s)) enrichedSongs.add(s);
          }
        }
      }

      return enrichedSongs;
    } catch (e) {
      debugPrint('YouTube fetchPlaylistSongs failed: $e');
      return [];
    }
  }

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

  Future<String?> createPlaylist(
      Map<String, String> headers, String title) async {
    try {
      final response = await http
          .post(
            Uri.parse('${_base}playlists?part=snippet,status'),
            headers: {
              ...headers,
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'snippet': {'title': title},
              'status': {'privacyStatus': 'private'},
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body);
        return data['id'];
      }
    } catch (e) {
      debugPrint('YouTube createPlaylist failed: $e');
    }
    return null;
  }

  Future<bool> deletePlaylist(Map<String, String> headers, String playlistId) async {
    try {
      final response = await http.delete(
        Uri.parse('${_base}playlists?id=$playlistId'),
        headers: headers,
      );
      if (response.statusCode == 204 || response.statusCode == 200) {
        return true;
      } else {
        debugPrint('YouTube deletePlaylist err: ${response.statusCode} ${response.body}');
        return false;
      }
    } catch (e) {
      debugPrint('YouTube deletePlaylist failed: $e');
      return false;
    }
  }

  Future<bool> editPlaylist(Map<String, String> headers, String id, String newTitle) async {
    try {
      final response = await http.put(
        Uri.parse('${_base}playlists?part=snippet'),
        headers: {
          ...headers,
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'id': id,
          'snippet': {'title': newTitle},
        }),
      );
      return response.statusCode == 200 || response.statusCode == 204;
    } catch (e) {
      debugPrint('YouTube editPlaylist failed: $e');
      return false;
    }
  }

  Future<bool> addSongToPlaylist(
    Map<String, String> headers,
    String playlistId,
    String videoId,
  ) async {
    try {
      final response = await http
          .post(
            Uri.parse('${_base}playlistItems?part=snippet'),
            headers: {
              ...headers,
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'snippet': {
                'playlistId': playlistId,
                'resourceId': {
                  'kind': 'youtube#video',
                  'videoId': videoId,
                }
              },
            }),
          )
          .timeout(const Duration(seconds: 15));
      return response.statusCode == 200 || response.statusCode == 201;
    } catch (e) {
      debugPrint('YouTube addSongToPlaylist failed: $e');
      return false;
    }
  }

  Future<bool> removeSongFromPlaylist(
    Map<String, String> headers,
    String playlistId,
    String videoId,
  ) async {
    try {
      // First, find the playlistItemId for this videoId in this playlist
      final items = await _fetchPagedItems(
        headers,
        'playlistItems',
        {
          'part': 'id,contentDetails',
          'playlistId': playlistId,
          'maxResults': '50',
        },
        maxPages: 100,
      );

      final item = items.firstWhere(
        (it) => it['contentDetails']?['videoId'] == videoId,
        orElse: () => null,
      );

      if (item != null) {
        final itemId = item['id'];
        final response = await http.delete(
          Uri.parse('${_base}playlistItems?id=$itemId'),
          headers: headers,
        );
        return response.statusCode == 200 || response.statusCode == 204;
      }
    } catch (e) {
      debugPrint('YouTube removeSongFromPlaylist failed: $e');
    }
    return false;
  }

  Future<void> rateSong(
      Map<String, String> headers, String videoId, String rating) async {
    try {
      debugPrint('YouTube rateSong: Syncing $rating to YouTube InnerTube backend...');
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
        // Fallback: Data API
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
        if (nextPageToken == null || items == null || items.isEmpty) break;
      } catch (e) {
        debugPrint('YouTube paged fetch error at page $i: $e');
        break;
      }
    }
    return allItems;
  }

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

  String _bestThumbnail(Map<String, dynamic>? thumbnails) {
    if (thumbnails == null) return '';
    final keys = ['maxres', 'standard', 'high', 'medium', 'default'];
    for (final key in keys) {
      if (thumbnails[key] != null) return thumbnails[key]['url'];
    }
    return '';
  }

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

class YoutubeAccountException implements Exception {
  final String message;
  const YoutubeAccountException(this.message);
  @override
  String toString() => message;
}
