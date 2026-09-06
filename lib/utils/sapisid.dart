import 'dart:convert';
import 'package:crypto/crypto.dart';

// Generates the special "SAPISIDHASH" Authorization header required by YouTube Music internal APIs.
// Google requires requests using authenticated cookies to include a timestamped SHA-1 hash of the
// user's SAPISID cookie combined with the web origin (https://music.youtube.com).
String generateSapisidHash(String cookieString) {
  // Fixed origin matching the YouTube Music web application.
  const origin = 'https://music.youtube.com';
  
  // Parse the cookie string to extract the SAPISID cookie value.
  String? sapisid;
  final parts = cookieString.split(';');
  for (final part in parts) {
    final trimmed = part.trim();
    if (trimmed.startsWith('SAPISID=')) {
      sapisid = trimmed.substring('SAPISID='.length);
      break;
    }
  }

  // If no SAPISID cookie is present in the cookie string, authentication hash cannot be generated.
  if (sapisid == null) return '';

  // Get the current Unix epoch time in seconds.
  final time = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  // Format required by YouTube: "{timestamp_in_seconds} {SAPISID} {origin}".
  final input = '$time $sapisid $origin';
  // Compute the SHA-1 hexadecimal digest.
  final hash = sha1.convert(utf8.encode(input)).toString();
  // Return standard formatted authorization string: "SAPISIDHASH {time}_{sha1_hash}".
  return 'SAPISIDHASH ${time}_$hash';
}
