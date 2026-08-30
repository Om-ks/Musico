with open('lib/services/youtube_account_service.dart', 'r', encoding='utf-8') as f:
    text = f.read()

# We will just cut off everything from the duplicate rateSong onwards.
index = text.rfind('  Future<void> rateSong(Map<String, String> headers, String videoId, String rating) async {')
if index != -1:
    text = text[:index]
    
with open('lib/services/youtube_account_service.dart', 'w', encoding='utf-8') as f:
    f.write(text)
