import 'dart:convert';
import 'package:crypto/crypto.dart';

String generateSapisidHash(String cookieString) {
  const origin = 'https://music.youtube.com';
  
  String? sapisid;
  final parts = cookieString.split(';');
  for (final part in parts) {
    final trimmed = part.trim();
    if (trimmed.startsWith('SAPISID=')) {
      sapisid = trimmed.substring('SAPISID='.length);
      break;
    }
  }

  if (sapisid == null) return '';

  final time = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final input = '$time $sapisid $origin';
  final hash = sha1.convert(utf8.encode(input)).toString();
  return 'SAPISIDHASH ${time}_$hash';
}
