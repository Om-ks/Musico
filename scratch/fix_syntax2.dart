import 'dart:io';

void main() {
  final ytService = File('lib/services/youtube_account_service.dart');
  var ytContent = ytService.readAsStringSync();
  
  final oldStr = '''            if (songs.isNotEmpty || playlists.isNotEmpty) {
               sections.add(MusicRecommendationSection(title: title, songs: songs, playlists: playlists));
            }
          }
        }
      } else {
        throw Exception('Failed to fetch home feed: \${response.statusCode}');
      }''';
      
  final newStr = '''            if (songs.isNotEmpty || playlists.isNotEmpty) {
               sections.add(MusicRecommendationSection(title: title, songs: songs, playlists: playlists));
            }
          }
        }
      }
      } else {
        throw Exception('Failed to fetch home feed: \${response.statusCode}');
      }''';
      
  ytContent = ytContent.replaceFirst(oldStr, newStr);
  
  ytService.writeAsStringSync(ytContent);
}
