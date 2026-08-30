import 'dart:isolate';

void main() async {
  await Isolate.resolvePackageUri(Uri.parse('package:dart_ytmusic_api/dart_ytmusic_api.dart'));
}
