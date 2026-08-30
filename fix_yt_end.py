with open('lib/services/youtube_account_service.dart', 'r', encoding='utf-8') as f:
    text = f.read()

# We need to move ateSong to inside YoutubeAccountService.
text = text.replace('}\n\nclass YoutubeAccountException implements Exception {', '')

# At the end, we re-add YoutubeAccountException
text = text.replace('''      debugPrint('Error rating song: ');
    }
  }
}''', '''      debugPrint('Error rating song: ');
    }
  }
}

class YoutubeAccountException implements Exception {
  final String message;
  const YoutubeAccountException(this.message);
  @override
  String toString() => message;
}
''')

with open('lib/services/youtube_account_service.dart', 'w', encoding='utf-8') as f:
    f.write(text)
