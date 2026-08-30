import re
with open('lib/widgets/mini_player.dart', 'r') as f:
    text = f.read()

text = re.sub(r"key: ValueKey\(\s*'.*',\s*\),", "key: ValueKey('${provider.isLoading}-${provider.isPlaying}'),", text)

with open('lib/widgets/mini_player.dart', 'w') as f:
    f.write(text)
