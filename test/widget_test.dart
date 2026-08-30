import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yt_music_clone/providers/player_provider.dart';
import 'package:yt_music_clone/screens/search_screen.dart';
import 'package:yt_music_clone/services/musico_audio_handler.dart';

void main() {
  testWidgets('Search screen renders music search controls', (tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => PlayerProvider(audioHandler: MusicoAudioHandler()),
        child: const MaterialApp(
          home: SearchScreen(),
        ),
      ),
    );

    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Search Musico'), findsOneWidget);
    expect(
      find.text('Type a song or artist name to load playable results.'),
      findsOneWidget,
    );
  });
}
