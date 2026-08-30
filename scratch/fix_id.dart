import 'dart:io';

void main() {
  final ytService = File('lib/services/youtube_account_service.dart');
  var ytContent = ytService.readAsStringSync();
  
  final oldIdStr = '''                final id = watchEndpoint?['videoId']?.toString() ??
                           watchEndpoint?['playlistId']?.toString() ??
                           playlistEndpoint?['playlistId']?.toString() ??
                           browseEndpoint?['browseId']?.toString();''';
                           
  final newIdStr = '''                final id = playlistEndpoint?['playlistId']?.toString() ??
                           watchEndpoint?['playlistId']?.toString() ??
                           browseEndpoint?['browseId']?.toString() ??
                           watchEndpoint?['videoId']?.toString();''';
                           
  ytContent = ytContent.replaceFirst(oldIdStr, newIdStr);
  
  ytService.writeAsStringSync(ytContent);
}
