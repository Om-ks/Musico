import 'dart:io';

void main() {
  final ytService = File('lib/services/youtube_account_service.dart');
  var ytContent = ytService.readAsStringSync();
  
  final oldStr = '''        }
      }
      } else {
        throw Exception('Failed to fetch home feed: \${response.statusCode}');
      }
    } catch (e) {
      debugPrint('Error fetching home feed: \$e');
      rethrow;
    }''';
      
  final newStr = '''        }
      }
      }
    } catch (e) {
      debugPrint('Error fetching home feed: \$e');
    }''';
      
  ytContent = ytContent.replaceFirst(oldStr, newStr);
  
  // also fix the unused variable warning
  final oldVar = '''                final isPlaylist = playlistEndpoint != null || 
                                   browseEndpoint?['browseEndpointContextSupportedConfigs']?['browseEndpointContextMusicConfig']?['pageType'] == 'MUSIC_PAGE_TYPE_PLAYLIST' ||
                                   (watchEndpoint != null && watchEndpoint['playlistId'] != null && watchEndpoint['playlistId'].toString().startsWith('RD'));''';
  ytContent = ytContent.replaceFirst(oldVar, '');
  
  ytService.writeAsStringSync(ytContent);
}
