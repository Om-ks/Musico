with open('lib/services/youtube_account_service.dart', 'r', encoding='utf-8') as f:
    text = f.read()

text = text.replace('Fetched \ songs.', 'Fetched \ songs.')

with open('lib/services/youtube_account_service.dart', 'w', encoding='utf-8') as f:
    f.write(text)
