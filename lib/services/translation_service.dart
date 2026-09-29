import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class TranslationResult {
  final String translation;
  final String? transliteration;
  final bool isEnglish;
  
  TranslationResult({required this.translation, this.transliteration, this.isEnglish = false});
}

class TranslationService {
  static Future<TranslationResult?> translate(String text) async {
    try {
      final query = Uri.encodeComponent(text);
      // Fetch English translation (tl=en) and transliteration/romanization (dt=rm)
      final url = 'https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=en&dt=t&dt=rm&q=$query';
      
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body);
      
      // Check detected source language
      bool isEnglish = false;
      if (data.length > 2 && data[2] is String) {
        if (data[2].toString().toLowerCase().startsWith('en')) {
          isEnglish = true;
          // If it's already English, we don't need to parse the rest
          return TranslationResult(translation: text, isEnglish: true);
        }
      }
      
      // Extract translated text
      String translatedText = '';
      String? transliteration;

      if (data[0] != null) {
        for (var i = 0; i < data[0].length; i++) {
          final block = data[0][i];
          if (block == null) continue;
          
          if (block.length > 0 && block[0] != null) {
             translatedText += block[0].toString();
          }
          if (block.length > 3 && block[3] != null) {
             transliteration = (transliteration ?? '') + block[3].toString();
          } else if (block.length > 2 && block[2] != null && block[0] == null && block[1] == null) {
             transliteration = (transliteration ?? '') + block[2].toString();
          }
        }
      }

      return TranslationResult(
        translation: translatedText.trim(),
        transliteration: transliteration?.trim(),
        isEnglish: isEnglish,
      );
    } catch (e) {
      debugPrint('Translation error: $e');
      return null;
    }
  }
}
