import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yt_music_clone/models/song.dart';
import 'package:yt_music_clone/services/musico_audio_handler.dart';

void main() {
  const firstSong = Song(
    id: 'first',
    title: 'First Track',
    artist: 'Artist One',
    album: 'Album',
    thumbnailUrl: 'https://example.com/first.jpg',
    duration: 180,
    source: 'youtube',
  );
  const secondSong = Song(
    id: 'second',
    title: 'Second Track',
    artist: 'Artist Two',
    album: 'Album',
    thumbnailUrl: 'https://example.com/second.jpg',
    duration: 210,
    source: 'youtube',
  );

  test('publishes normal playback notification controls', () {
    final handler = MusicoAudioHandler();

    handler.publish(
      currentSong: firstSong,
      songs: const [firstSong, secondSong],
      queueIndex: 0,
      playing: true,
      loading: false,
      position: const Duration(seconds: 42),
      duration: const Duration(minutes: 3),
      speed: 1,
      shuffleOn: false,
      repeatOne: false,
      hasError: false,
    );

    final state = handler.playbackState.value;
    expect(state.processingState, AudioProcessingState.ready);
    expect(state.playing, isTrue);
    expect(state.queueIndex, 0);
    expect(state.androidCompactActionIndices, const [0, 1, 2]);
    expect(state.controls.map((control) => control.action), [
      MediaAction.skipToPrevious,
      MediaAction.pause,
      MediaAction.skipToNext,
      MediaAction.stop,
    ]);
    expect(state.controls.last.label, 'Close');
    expect(state.controls.last.androidIcon, 'drawable/audio_service_close');
    expect(handler.mediaItem.value?.id, 'youtube:first');
    expect(handler.queue.value.map((item) => item.id), [
      'youtube:first',
      'youtube:second',
    ]);
  });

  test('publishes buffering state and loading control while preparing audio',
      () {
    final handler = MusicoAudioHandler();

    handler.publish(
      currentSong: secondSong,
      songs: const [firstSong, secondSong],
      queueIndex: 1,
      playing: false,
      loading: true,
      position: Duration.zero,
      duration: const Duration(minutes: 3, seconds: 30),
      speed: 1,
      shuffleOn: false,
      repeatOne: false,
      hasError: false,
    );

    final state = handler.playbackState.value;
    expect(state.processingState, AudioProcessingState.buffering);
    expect(state.playing, isTrue);
    expect(state.queueIndex, 1);
    expect(state.controls[1].label, 'Loading');
    expect(state.controls[1].androidIcon, 'drawable/audio_service_loading');
    expect(state.controls[1].action, MediaAction.pause);
    expect(handler.mediaItem.value?.id, 'youtube:second');
  });

  test('clears notification state when no song is active', () {
    final handler = MusicoAudioHandler();

    handler.publish(
      currentSong: firstSong,
      songs: const [firstSong],
      queueIndex: 0,
      playing: true,
      loading: false,
      position: Duration.zero,
      duration: const Duration(minutes: 3),
      speed: 1,
      shuffleOn: false,
      repeatOne: false,
      hasError: false,
    );
    handler.publish(
      currentSong: null,
      songs: const [],
      queueIndex: 0,
      playing: false,
      loading: false,
      position: Duration.zero,
      duration: Duration.zero,
      speed: 1,
      shuffleOn: false,
      repeatOne: false,
      hasError: false,
    );

    expect(handler.mediaItem.value, isNull);
    expect(handler.queue.value, isEmpty);
    expect(handler.playbackState.value.controls, isEmpty);
  });
}
