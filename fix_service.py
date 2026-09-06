import re

with open('lib/services/youtube_account_service.dart', 'r', encoding='utf-8') as f:
    content = f.read()

# Fix 1: fetchHomeFeed params
old_home = "  Future<HomeFeedData> fetchHomeFeed(Map<String, String> headers, {String? continuationToken}) async {"
new_home = "  Future<HomeFeedData> fetchHomeFeed(Map<String, String> headers, {String? params}) async {"
content = content.replace(old_home, new_home)

old_body_cont = '''      if (continuationToken != null) {
        body['continuation'] = continuationToken;
      } else {
        body['browseId'] = 'FEmusic_home';
      }'''
new_body_cont = '''      body['browseId'] = 'FEmusic_home';
      if (params != null) {
        body['params'] = params;
      }'''
content = content.replace(old_body_cont, new_body_cont)

old_chip = '''            for (final chip in headerChips) {
              final renderer = chip['chipCloudChipRenderer'];
              final text = renderer?['text']?['runs']?[0]?['text']?.toString();
              final token = renderer?['navigationEndpoint']?['continuationCommand']?['token']?.toString();
              if (text != null && text.isNotEmpty) {
                chips.add(HomeFeedChip(text: text, token: token));
              }
            }'''
new_chip = '''            for (final chip in headerChips) {
              final renderer = chip['chipCloudChipRenderer'];
              final text = renderer?['text']?['runs']?[0]?['text']?.toString();
              final chipParams = renderer?['navigationEndpoint']?['browseEndpoint']?['params']?.toString();
              if (text != null && text.isNotEmpty) {
                chips.add(HomeFeedChip(text: text, token: chipParams));
              }
            }'''
content = content.replace(old_chip, new_chip)

# Fix 2: fetchPlaylists
old_playlists = '''        try {
          final items = data['contents']?['singleColumnBrowseResultsRenderer']
                  ?['tabs']?[0]?['tabRenderer']?['content']
              ?['sectionListRenderer']?['contents']?[0]?['gridRenderer']
              ?['items'] as List?;

          if (items != null) {
            for (final item in items) {
              final renderer = item['musicTwoRowItemRenderer'];
              if (renderer == null) continue;

              final title = renderer['title']?['runs']?[0]?['text']?.toString();
              final browseEndpoint =
                  renderer['navigationEndpoint']?['browseEndpoint'];
              final playlistId = browseEndpoint?['browseId']?.toString();

              if (title != null && playlistId != null) {
                final rawSubtitle = (renderer['subtitle']?['runs'] as List?)
                        ?.map((r) => r['text']?.toString() ?? '')
                        .join('') ??
                    '';'''
new_playlists = '''        try {
          List<dynamic> items = [];
          
          void findPlaylists(dynamic node) {
            if (node is Map) {
              if (node.containsKey('musicTwoRowItemRenderer')) {
                items.add(node['musicTwoRowItemRenderer']);
              } else {
                node.values.forEach(findPlaylists);
              }
            } else if (node is List) {
              node.forEach(findPlaylists);
            }
          }
          findPlaylists(data);

          if (items.isNotEmpty) {
            for (final renderer in items) {
              final title = renderer['title']?['runs']?[0]?['text']?.toString();
              final browseEndpoint =
                  renderer['navigationEndpoint']?['browseEndpoint'];
              final playlistId = browseEndpoint?['browseId']?.toString();

              if (title != null && playlistId != null) {
                final rawSubtitle = (renderer['subtitle']?['runs'] as List?)
                        ?.map((r) => r['text']?.toString() ?? '')
                        .join('') ??
                    '';'''
content = content.replace(old_playlists, new_playlists)

with open('lib/services/youtube_account_service.dart', 'w', encoding='utf-8') as f:
    f.write(content)
