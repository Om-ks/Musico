with open('lib/providers/account_provider.dart', 'r', encoding='utf-8') as f:
    text = f.read()

text = text.replace('  bool _explicitSignOut = false;\n', '')
text = text.replace('      _explicitSignOut = true;\n', '')
text = text.replace('        _explicitSignOut = false;\n', '')
text = text.replace('  bool get _hasCachedYoutubeState =>\n      _cachedDisplayName != null ||\n      _cachedEmail != null ||\n      _cachedPhotoUrl != null ||\n      _library.likedSongs.isNotEmpty ||\n      _library.playlists.isNotEmpty;\n', '')

with open('lib/providers/account_provider.dart', 'w', encoding='utf-8') as f:
    f.write(text)
