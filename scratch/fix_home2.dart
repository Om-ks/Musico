import 'dart:io';

void main() {
  final file = File('lib/screens/home_screen.dart');
  var lines = file.readAsLinesSync();
  
  // Remove lines 0 to 16 (which is lines 1-17, the duplicates)
  lines.removeRange(0, 17);
  
  file.writeAsStringSync(lines.join('\n'));
}
