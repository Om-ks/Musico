import 'dart:io';

void main() {
  final ytService = File('lib/services/youtube_account_service.dart');
  var ytContent = ytService.readAsStringSync();
  
  // Remove the duplicate rateSong method at the end of the file
  final pattern = RegExp(r'Future<void> rateSong\(Map<String, String> headers, String videoId, String rating\) async \{.*?\}\n', dotAll: true);
  final matches = pattern.allMatches(ytContent).toList();
  
  if (matches.length > 1) {
    // Keep the first one, remove the second one (the one I just added)
    final matchToRemove = matches.last;
    ytContent = ytContent.replaceRange(matchToRemove.start, matchToRemove.end, '');
    ytService.writeAsStringSync(ytContent);
  }
  
  final ap = File('lib/providers/account_provider.dart');
  var apContent = ap.readAsStringSync();
  final apPattern = RegExp(r'Future<void> rateSong\(String videoId, bool isLiked\) async \{.*?\}\n', dotAll: true);
  final apMatches = apPattern.allMatches(apContent).toList();
  if (apMatches.isNotEmpty) {
    final matchToRemove = apMatches.last;
    apContent = apContent.replaceRange(matchToRemove.start, matchToRemove.end, '');
    ap.writeAsStringSync(apContent);
  }
}
