import 'dart:convert';
import 'dart:io';

String? _extractContinuationToken(dynamic data, {bool isPlaylist = false}) {
    String? token;
    void find(dynamic node) {
      if (token != null || node == null) return;
      if (node is Map) {
        // Skip these subtrees completely to avoid looping chips or autoplay tokens
        if (node.containsKey('musicBottomActionRenderer') ||
            node.containsKey('automixPreviewVideoRenderer') ||
            node.containsKey('chipCloudRenderer') ||
            node.containsKey('chipCloudChipRenderer')) {
          return;
        }
        
        if (isPlaylist && node.containsKey('itemSectionRenderer')) {
          return;
        }

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

    // For playlists, try to restrict to the playlist shelf first to avoid grabbing related/mix tokens
    try {
      final shelf = data['contents']?['singleColumnBrowseResultsRenderer']?['tabs']?[0]?['tabRenderer']?['content']?['sectionListRenderer']?['contents']?[0]?['musicPlaylistShelfRenderer'] ??
                    data['contents']?['singleColumnBrowseResultsRenderer']?['tabs']?[0]?['tabRenderer']?['content']?['sectionListRenderer']?['contents']?[0]?['musicShelfRenderer'] ??
                    data['contents']?['twoColumnBrowseResultsRenderer']?['secondaryContents']?['sectionListRenderer']?['contents']?[0]?['musicPlaylistShelfRenderer'] ??
                    data['continuationContents']?['musicPlaylistShelfContinuation'] ??
                    data['continuationContents']?['musicShelfContinuation'];
      if (shelf != null) {
        find(shelf['continuations']);
        if (token != null) return token;
      }
    } catch (_) {}
    
    // If it's a playlist, we strictly DO NOT fall back to global recursive search, 
    // because that will find the 'Suggested songs' section and loop endlessly.
    if (isPlaylist) return token;

    find(data);
    return token;
}

void main() {
  final payload = {
    'contents': {
      'singleColumnBrowseResultsRenderer': {
        'tabs': [
          {
            'tabRenderer': {
              'content': {
                'sectionListRenderer': {
                  'contents': [
                    {
                      'musicShelfRenderer': {
                        'contents': [],
                        'continuations': [
                          {
                            'nextContinuationData': {
                              'continuation': 'LIKED_SONGS_TOKEN'
                            }
                          }
                        ]
                      }
                    }
                  ]
                }
              }
            }
          }
        ]
      }
    }
  };
  
  print('Token: ' + _extractContinuationToken(payload, isPlaylist: true).toString());
}

