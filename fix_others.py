import re

# Fix account_provider.dart:732
with open('lib/providers/account_provider.dart', 'r', encoding='utf-8') as f:
    text = f.read()

# find unnecessary override
text = re.sub(r'  @override\n  void dispose\(\) \{\n    super.dispose\(\);\n  \}\n', '', text)

with open('lib/providers/account_provider.dart', 'w', encoding='utf-8') as f:
    f.write(text)

# Fix youtube_account_service.dart
with open('lib/services/youtube_account_service.dart', 'r', encoding='utf-8') as f:
    text = f.read()

text = text.replace('final sapisidMatch = RegExp(r\'SAPISID=([^;]+)\').firstMatch(cookieString);', 'final sapisidMatch = RegExp(r\'SAPISID=([^;]+)\').firstMatch(cookieString);')
# Actually wait, let me use regex to fix the unneeded escape
text = re.sub(r"RegExp\(r\\'SAPISID=\(\[\^;\]\+\)\\'\)", r"RegExp(r'SAPISID=([^;]+)')", text)

with open('lib/services/youtube_account_service.dart', 'w', encoding='utf-8') as f:
    f.write(text)
