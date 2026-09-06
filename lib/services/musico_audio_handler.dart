import 'dart:async';

import 'package:audio_service/audio_service.dart';

import '../models/song.dart';

// Type alias for asynchronous playback control callbacks without parameters (play, pause, stop, etc.).
typedef PlaybackCallback = Future<void> Function();

// Type alias for position seek callbacks accepting the target playback duration.
typedef SeekCallback = Future<void> Function(Duration position);

// Background audio handler that interfaces with the operating system's media session and notification shade.
// Extends BaseAudioHandler from audio_service to display lock screen controls, notification actions,
// and handle headphone button events.
class MusicoAudioHandler extends BaseAudioHandler {
  // Notification media control button that closes/stops the background playback session.
  static const MediaControl _closeControl = MediaControl(
    androidIcon: 'drawable/audio_service_close',
    label: 'Close',
    action: MediaAction.stop,
  );

  // Notification media control button indicating that the track is actively buffering.
  static const MediaControl _loadingControl = MediaControl(
    androidIcon: 'drawable/audio_service_loading',
    label: 'Loading',
    action: MediaAction.pause,
  );

  // Custom media control button shown in notification to toggle repeat mode ON.
  static final MediaControl _repeatOffControl = MediaControl.custom(
    androidIcon: 'drawable/audio_service_repeat',
    label: 'Repeat Off',
    name: 'repeatOff',
  );

  // Custom media control button shown in notification to toggle repeat mode OFF.
  static final MediaControl _repeatOneControl = MediaControl.custom(
    androidIcon: 'drawable/audio_service_repeat_one',
    label: 'Repeat One',
    name: 'repeatOne',
  );

  // Delegate callback invoked when user taps Play from system notification or lock screen.
  PlaybackCallback? onPlayRequested;

  // Delegate callback invoked when user taps Pause from system notification or lock screen.
  PlaybackCallback? onPauseRequested;

  // Delegate callback invoked when user taps Stop/Close from system notification.
  PlaybackCallback? onStopRequested;

  // Delegate callback invoked when user taps Next Track from notification or headset.
  PlaybackCallback? onNextRequested;

  // Delegate callback invoked when user taps Previous Track from notification or headset.
  PlaybackCallback? onPreviousRequested;

  // Delegate callback invoked when user scrubs the lock screen progress bar.
  SeekCallback? onSeekRequested;

  // Delegate callback invoked when user toggles repeat mode from the notification.
  Function(AudioServiceRepeatMode)? onRepeatModeRequested;

  // Fingerprint signature of current playlist to prevent redundant queue broadcasts.
  String? _lastQueueSignature;

  // Cached ID of current media item to detect track changes.
  String? _lastMediaId;

  // Inactivity timer that kills background playback after 1 hour of paused state.
  Timer? _inactivityTimer;

  // Constructor that initializes the playback state stream with an empty state.
  MusicoAudioHandler() {
    playbackState.add(PlaybackState());
  }

  // Connects the UI/PlayerProvider audio control functions to this system audio handler.
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

  // Broadcasts current playback snapshot (song metadata, queue, progress, controls)
  // to the operating system notification and lock screen.
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
    // If no song is loaded, clear notification and reset state.
    if (currentSong == null) {
      _lastQueueSignature = null;
      _lastMediaId = null;
      queue.add(const []);
      mediaItem.add(null);
      playbackState.add(PlaybackState());
      return;
    }

    // Convert songs to audio_service MediaItem instances.
    final items = songs.isEmpty
        ? [_mediaItemFor(currentSong)]
        : songs.map(_mediaItemFor).toList(growable: false);
    final safeIndex =
        queueIndex >= 0 && queueIndex < items.length ? queueIndex : 0;

    // Check if queue has actually changed before broadcasting to system.
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



    // Assemble notification media control buttons based on current playback state.
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

    // Push full playback state to OS notification and lock screen.
    playbackState.add(
      PlaybackState(
        controls: controls,
        // Indices of actions shown in Android's collapsed notification view.
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

  // Converts our internal Song model into an audio_service MediaItem object.
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

  // Handles Play command triggered from notification, headset button, or Android Auto.
  @override
  Future<void> play() async {
    _inactivityTimer?.cancel();
    await onPlayRequested?.call();
  }

  // Handles Pause command and schedules a 1-hour auto-stop timer to free system resources.
  @override
  Future<void> pause() async {
    _inactivityTimer?.cancel();
    _inactivityTimer = Timer(const Duration(hours: 1), () async {
      await stop();
    });
    await onPauseRequested?.call();
  }

  // Handles Stop command, canceling timers and halting background service.
  @override
  Future<void> stop() async {
    _inactivityTimer?.cancel();
    await onStopRequested?.call();
  }

  // Called when user swipes the app away from recent tasks.
  @override
  Future<void> onTaskRemoved() async {
    // Stop playback and destroy the service when the app is swiped away from recents.
    // This prevents ghost media notifications and broken PlayerProvider connections.
    await stop();
  }

  // Handles Skip To Next command from notification or lock screen.
  @override
  Future<void> skipToNext() async {
    await onNextRequested?.call();
  }

  // Handles Skip To Previous command from notification or lock screen.
  @override
  Future<void> skipToPrevious() async {
    await onPreviousRequested?.call();
  }

  // Handles jumping directly to an item index within the playback queue.
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

  // Handles seeking to a specific time duration within the song.
  @override
  Future<void> seek(Duration position) async {
    await onSeekRequested?.call(position);
  }

  // Handles repeat mode toggles dispatched from system audio interfaces.
  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    await onRepeatModeRequested?.call(repeatMode);
  }

  // Handles custom action button clicks from the notification (e.g. repeatOff / repeatOne).
  @override
  Future<void> customAction(String name, [Map<String, dynamic>? extras]) async {
    if (name == 'repeatOff') {
      await onRepeatModeRequested?.call(AudioServiceRepeatMode.one);
    } else if (name == 'repeatOne') {
      await onRepeatModeRequested?.call(AudioServiceRepeatMode.none);
    }
  }
}
