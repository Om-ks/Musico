import 'dart:async';

import 'package:audio_service/audio_service.dart';

import '../models/song.dart';

typedef PlaybackCallback = Future<void> Function();
typedef SeekCallback = Future<void> Function(Duration position);

class MusicoAudioHandler extends BaseAudioHandler {
  static const MediaControl _closeControl = MediaControl(
    androidIcon: 'drawable/audio_service_close',
    label: 'Close',
    action: MediaAction.stop,
  );
  static const MediaControl _loadingControl = MediaControl(
    androidIcon: 'drawable/audio_service_loading',
    label: 'Loading',
    action: MediaAction.pause,
  );
  static final MediaControl _repeatOffControl = MediaControl.custom(
    androidIcon: 'drawable/audio_service_repeat',
    label: 'Repeat Off',
    name: 'repeatOff',
  );
  static final MediaControl _repeatOneControl = MediaControl.custom(
    androidIcon: 'drawable/audio_service_repeat_one',
    label: 'Repeat One',
    name: 'repeatOne',
  );

  PlaybackCallback? onPlayRequested;
  PlaybackCallback? onPauseRequested;
  PlaybackCallback? onStopRequested;
  PlaybackCallback? onNextRequested;
  PlaybackCallback? onPreviousRequested;
  SeekCallback? onSeekRequested;
  Function(AudioServiceRepeatMode)? onRepeatModeRequested;
  String? _lastQueueSignature;
  String? _lastMediaId;

  MusicoAudioHandler() {
    playbackState.add(PlaybackState());
  }

  void bind({
    required PlaybackCallback onPlay,
    required PlaybackCallback onPause,
    required PlaybackCallback onStop,
    required PlaybackCallback onNext,
    required PlaybackCallback onPrevious,
    required SeekCallback onSeek,
    required Function(AudioServiceRepeatMode) onRepeatMode,
  }) {
    onPlayRequested = onPlay;
    onPauseRequested = onPause;
    onStopRequested = onStop;
    onNextRequested = onNext;
    onPreviousRequested = onPrevious;
    onSeekRequested = onSeek;
    onRepeatModeRequested = onRepeatMode;
  }

  void publish({
    required Song? currentSong,
    required List<Song> songs,
    required int queueIndex,
    required bool playing,
    required bool loading,
    required Duration position,
    required Duration duration,
    required double speed,
    required bool shuffleOn,
    required bool repeatOne,
    required bool hasError,
  }) {
    if (currentSong == null) {
      _lastQueueSignature = null;
      _lastMediaId = null;
      queue.add(const []);
      mediaItem.add(null);
      playbackState.add(PlaybackState());
      return;
    }

    final items = songs.isEmpty
        ? [_mediaItemFor(currentSong)]
        : songs.map(_mediaItemFor).toList(growable: false);
    final safeIndex =
        queueIndex >= 0 && queueIndex < items.length ? queueIndex : 0;

    final queueSignature = items.map((item) => item.id).join('|');
    if (_lastQueueSignature != queueSignature) {
      _lastQueueSignature = queueSignature;
      queue.add(items);
    }

    var currentItem = items[safeIndex];
    if (duration > Duration.zero) {
      currentItem = currentItem.copyWith(duration: duration);
    }

    // Always push the updated currentItem if ID changed, OR if duration changed (we can just always emit it, or check previous).
    // The safest is to just update it if the duration is different.
    final oldItem = mediaItem.valueOrNull;
    if (_lastMediaId != currentItem.id || (oldItem != null && oldItem.duration != currentItem.duration)) {
      _lastMediaId = currentItem.id;
      mediaItem.add(currentItem);
    }



    final controls = <MediaControl>[
      MediaControl.skipToPrevious,
      loading
          ? _loadingControl
          : playing
              ? MediaControl.pause
              : MediaControl.play,
      MediaControl.skipToNext,
      repeatOne ? _repeatOneControl : _repeatOffControl,
      _closeControl,
    ];

    playbackState.add(
      PlaybackState(
        controls: controls,
        androidCompactActionIndices: const [1, 2, 3],
        systemActions: const {
          MediaAction.seek,
          MediaAction.skipToPrevious,
          MediaAction.skipToNext,
          MediaAction.setRepeatMode,
        },
        processingState: hasError
            ? AudioProcessingState.error
            : loading
                ? AudioProcessingState.buffering
                : AudioProcessingState.ready,
        playing: playing || loading,
        updatePosition: position,
        bufferedPosition: duration,
        speed: speed,
        updateTime: DateTime.now(),
        repeatMode: repeatOne
            ? AudioServiceRepeatMode.one
            : AudioServiceRepeatMode.none,
        shuffleMode: shuffleOn
            ? AudioServiceShuffleMode.all
            : AudioServiceShuffleMode.none,
        queueIndex: safeIndex,
      ),
    );
  }

  MediaItem _mediaItemFor(Song song) {
    final duration =
        song.duration > 0 ? Duration(seconds: song.duration) : null;
    return MediaItem(
      id: '${song.source}:${song.id}',
      album: song.album,
      title: song.title,
      artist: song.artist,
      duration: duration,
      artUri:
          song.thumbnailUrl.isNotEmpty ? Uri.tryParse(song.thumbnailUrl) : null,
      extras: {
        'source': song.source,
        'songId': song.id,
      },
    );
  }

  @override
  Future<void> play() async {
    await onPlayRequested?.call();
  }

  @override
  Future<void> pause() async {
    await onPauseRequested?.call();
  }

  @override
  Future<void> stop() async {
    await onStopRequested?.call();
  }

  @override
  Future<void> skipToNext() async {
    await onNextRequested?.call();
  }

  @override
  Future<void> skipToPrevious() async {
    await onPreviousRequested?.call();
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    final currentIndex = playbackState.value.queueIndex;
    if (currentIndex == null) return;
    if (index < currentIndex) {
      await skipToPrevious();
    } else if (index > currentIndex) {
      await skipToNext();
    }
  }

  @override
  Future<void> seek(Duration position) async {
    await onSeekRequested?.call(position);
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    await onRepeatModeRequested?.call(repeatMode);
  }

  @override
  Future<void> customAction(String name, [Map<String, dynamic>? extras]) async {
    if (name == 'repeatOff') {
      await onRepeatModeRequested?.call(AudioServiceRepeatMode.one);
    } else if (name == 'repeatOne') {
      await onRepeatModeRequested?.call(AudioServiceRepeatMode.none);
    }
  }
}
