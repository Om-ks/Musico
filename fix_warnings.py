import re

with open('lib/providers/account_provider.dart', 'r', encoding='utf-8') as f:
    text = f.read()
    
# Remove _hasCachedYoutubeState
text = re.sub(r'  bool get _hasCachedYoutubeState =>[\s\S]*?;\n', '', text)

with open('lib/providers/account_provider.dart', 'w', encoding='utf-8') as f:
    f.write(text)


with open('lib/services/youtube_account_service.dart', 'r', encoding='utf-8') as f:
    text = f.read()
    
# Remove unused cookieString at line 277
text = re.sub(r'      final cookieString = headers\[\'Cookie\'\] \?\? \'\';\n      \n      final requestHeaders', '      final requestHeaders', text)

# Remove unused _bestThumbnailFromDynamic
text = re.sub(r'  String _bestThumbnailFromDynamic\(dynamic thumbnails\) \{[\s\S]*?  \}\n\n  String _unescape\(String text\)', '  String _unescape(String text)', text)

with open('lib/services/youtube_account_service.dart', 'w', encoding='utf-8') as f:
    f.write(text)


with open('lib/utils/sapisid.dart', 'r', encoding='utf-8') as f:
    text = f.read()

text = text.replace('final origin =', 'const origin =')

with open('lib/utils/sapisid.dart', 'w', encoding='utf-8') as f:
    f.write(text)


with open('lib/widgets/mini_player.dart', 'r', encoding='utf-8') as f:
    text = f.read()

text = text.replace("import 'package:glass_container/glass_container.dart';\n", "")

with open('lib/widgets/mini_player.dart', 'w', encoding='utf-8') as f:
    f.write(text)
