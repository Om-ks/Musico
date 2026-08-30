import 'dart:io';

void main() {
  final ytService = File('lib/services/youtube_account_service.dart');
  var ytContent = ytService.readAsStringSync();
  
  ytContent = ytContent.replaceFirst('''          }
        }
      }
    } catch (e) {
      debugPrint('Error fetching home feed: \$e');
    }''', '''          }
        }
      }
      }
    } catch (e) {
      debugPrint('Error fetching home feed: \$e');
    }''');
    
  ytService.writeAsStringSync(ytContent);
  
  final ap = File('lib/providers/account_provider.dart');
  var apContent = ap.readAsStringSync();
  
  apContent = apContent.replaceFirst('final headers = await _authHeaders;', 'final headers = await getAuthHeaders();');
  ap.writeAsStringSync(apContent);
}
