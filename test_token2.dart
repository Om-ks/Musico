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

    find(data);
    return token;
}

void main() async {
  final payload = {
    'sectionListContinuation': {
      'contents': [
        {
          'chipCloudRenderer': {
            'continuations': [
              {
                'nextContinuationData': {
                  'continuation': 'BAD_CHIP_TOKEN'
                }
              }
            ]
          }
        },
        {
          'musicShelfRenderer': {
            'continuations': [
              {
                'nextContinuationData': {
                  'continuation': 'GOOD_SHELF_TOKEN'
                }
              }
            ]
          }
        }
      ]
    }
  };
  
  print('Extracted: ' + _extractContinuationToken(payload, isPlaylist: false).toString());
}

