import re

with open('lib/services/youtube_account_service.dart', 'r', encoding='utf-8') as f:
    content = f.read()

new_func = \"\"\"  String? _extractContinuationToken(dynamic data) {
    String? token;
    void find(dynamic node) {
      if (token != null || node == null) return;
      if (node is Map) {
        if (node.containsKey('musicBottomActionRenderer') || 
            node.containsKey('automixPreviewVideoRenderer')) return;
        
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
    
    try {
      final shelf = data['contents']?['singleColumnBrowseResultsRenderer']?['tabs']?[0]?['tabRenderer']?['content']?['sectionListRenderer']?['contents']?[0]?['musicPlaylistShelfRenderer'] ??
                    data['contents']?['twoColumnBrowseResultsRenderer']?['secondaryContents']?['sectionListRenderer']?['contents']?[0]?['musicPlaylistShelfRenderer'] ??
                    data['continuationContents']?['musicPlaylistShelfContinuation'];
      if (shelf != null) {
        find(shelf['continuations']);
        if (token != null) return token;
      }
    } catch (_) {}
    
    find(data);
    return token;
  }\"\"\"

content = re.sub(r'  String\? _extractContinuationToken\(dynamic data\) \{.*?(?=\n  [A-Za-z]+\s+\w+\()', new_func + '\n', content, flags=re.DOTALL)

with open('lib/services/youtube_account_service.dart', 'w', encoding='utf-8') as f:
    f.write(content)
