import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/song.dart';
import '../services/api_service.dart';
import '../services/download_service.dart';
import '../services/musico_audio_handler.dart';
import '../services/storage_service.dart';
import '../services/youtube_account_service.dart';
import 'account_provider.dart';

// Represents possible failure states encountered during audio playback.
enum PlayerError { 
  none,               // Playback is normal without errors.
  streamUnavailable,  // Audio stream URL could not be resolved or expired.
  networkError        // Network connection dropped or timed out.
}

// The core audio playback controller for the entire application.
//
// Extends ChangeNotifier to notify UI widgets when playback state changes (position, play/pause,
// current song, loading, volume/effects, etc.). Integrates with just_audio for sound decoding,
// audio_service for background lockscreen controls, and native platform channels for audio effects.
class PlayerProvider extends ChangeNotifier {
  // Lower timeout so failed or unresponsive stream URLs fail fast instead of freezing the UI.
  static const Duration _streamLoadTimeout = Duration(seconds: 10);
  static const Duration _localLoadTimeout = Duration(seconds: 8);

  // Platform channel to communicate with native Android audio effects (Equalizer, Bass Boost, Reverb).
  static const MethodChannel _effectsChannel =
      MethodChannel('musico/audio_effects');

  // Platform channel to export songs to the Android system Downloads folder.
  static const MethodChannel _filesChannel =
      MethodChannel('musico/device_files');

  // The underlying audio player instance from the just_audio library.
  // Configured with aggressive buffering thresholds to begin playback after only 500ms.
  final AudioPlayer _player = AudioPlayer(
    audioLoadConfiguration: const AudioLoadConfiguration(
      androidLoadControl: AndroidLoadControl(
        // Start playback after buffering only 500ms — similar to Spotify and YouTube Music.
        // The player continues buffering the rest of the song in the background while playing.
        minBufferDuration: Duration(seconds: 15),
        maxBufferDuration: Duration(seconds: 90),
        bufferForPlaybackDuration: Duration(milliseconds: 500),
        bufferForPlaybackAfterRebufferDuration: Duration(milliseconds: 1500),
        prioritizeTimeOverSizeThresholds: true,
        backBufferDuration: Duration(seconds: 30),
      ),
    ),
  );

  // Local persistent storage service for likes, history, and downloads.
  final StorageService storage = StorageService();

  // Service for downloading audio files from streams to local storage.
  final DownloadService _downloadService = DownloadService();

  // Background audio handler managing system notifications and lockscreen controls.
  final MusicoAudioHandler _audioHandler;

  // Currently playing song metadata.
  Song? _currentSong;

  // The active playback queue/playlist.
  List<Song> _queue = [];

  // Current index of the playing song in the queue.
  int _queueIndex = 0;

  // True if audio is actively playing; false if paused or stopped.
  bool _isPlaying = false;

  // True if a song is actively loading or buffering data.
  bool _isLoading = false;

  // Current playback position in the song.
  Duration _position = Duration.zero;
  Duration _lastValidPosition = Duration.zero;

  // Total duration of the currently playing song.
  Duration _duration = Duration.zero;

  // Current playback error status.
  PlayerError _error = PlayerError.none;

  // Playback speed multiplier (1.0 = normal speed, range 0.5 to 2.0).
  double _speed = 1.0;

  // Playback pitch multiplier (1.0 = normal pitch, range 0.5 to 2.0).
  double _pitch = 1.0;

  // Bass boost intensity level (0.0 to 1.0).
  double _bass = 0.0;

  // Environmental reverb intensity level (0.0 to 1.0).
  double _reverb = 0.0;

  // When true, allows independent pitch control without changing playback speed.
  bool _pitchEnabled = false;

  // When true, songs in the queue will be played in randomized order.
  bool _shuffleOn = false;

  // When true, repeats the currently playing song in an infinite loop.
  bool _repeatOne = false;

  // Cached like status of the current song.
  bool _isLiked = false;

  // Guard flag preventing multiple simultaneous auto-advance transitions.
  bool _autoAdvancing = false;

  // Optional reference to AccountProvider for syncing liked songs with YouTube Music.
  AccountProvider? _account;

  // Internal list of songs added to the player's underlying playlist source.
  final List<Song> _sourceSongs = [];

  // Keys ('source:id') of songs currently added to the player's audio source.
  final Set<String> _sourceKeys = {};

  // Maps song keys to local file system paths for downloaded songs.
  final Map<String, String> _downloadPaths = {};

  // Set of song keys currently in the process of downloading.
  final Set<String> _downloadingKeys = {};

  // Maps song keys to current download progress fraction (0.0 to 1.0).
  final Map<String, double> _downloadProgress = {};

  // Set of song keys currently being exported to the public device storage.
  final Set<String> _exportingKeys = {};

  // Monotonically increasing revision counter for recently played history updates.
  int _recentRevision = 0;

  // Tracks the last index notified by just_audio's playlist source to detect changes.
  int? _lastAudioSourceIndex;

  // Unique incrementing ID for play requests to cancel outdated async operations.
  int _playRequestId = 0;

  // Remembers which song key has already triggered track completion to avoid double advancing.
  String? _completionHandledForKey;

  // Timestamp until which loading spinners are suppressed during interactive seeks or scratches.
  DateTime _seekLoadingSuppressedUntil = DateTime.fromMillisecondsSinceEpoch(0);

  // Throttles speed and pitch updates during vinyl scratch interactions.
  DateTime _lastScratchSpeedSyncAt = DateTime.fromMillisecondsSinceEpoch(0);

  // Prevents re-entrant error recovery loops.
  bool _recoveringPlaybackError = false;

  // Timestamp of the last error recovery attempt to avoid rapid retry cascades.
  DateTime _lastPlaybackRecoveryAt = DateTime.fromMillisecondsSinceEpoch(0);

  // Watchdog timer that triggers recovery if player is stuck buffering for too long.
  Timer? _bufferingWatchdog;

  // Tracks whether any audible audio has successfully played from the current stream.
  bool _hasPlayedSomeAudio = false;

  // Getters providing read-only access to player state properties for UI widgets.
  Song? get currentSong => _currentSong;
  List<Song> get queue => _queue;
  bool get isPlaying => _isPlaying;
  bool get isLoading => _isLoading;
  Duration get position => _position;
  Duration get duration => _duration;
  PlayerError get error => _error;
  double get speed => _speed;
  double get pitch => _pitch;
  double get bass => _bass;
  double get reverb => _reverb;
  bool get pitchEnabled => _pitchEnabled;
  bool get shuffleOn => _shuffleOn;
  bool get repeatOne => _repeatOne;

  // Returns true if the current song is favorited, checking both account library and local storage.
  bool get isLiked {
    if (_currentSong == null) return false;
    if (_account != null && _account!.library.likedSongs.any((s) => s.id == _currentSong!.id)) {
      return true;
    }
    return _isLiked;
  }

  // Reference to the underlying AudioPlayer engine.
  AudioPlayer get player => _player;

  // Revision counter tracking changes to recently played songs.
  int get recentRevision => _recentRevision;

  // Constructor attaches background notification actions, initializes stream listeners,
  // configures the audio session, and prepares audio settings.
  PlayerProvider({required MusicoAudioHandler audioHandler})
      : _audioHandler = audioHandler {
    // Bind media notification button actions (lockscreen, status bar, Bluetooth controls).
    _audioHandler.bind(
      onPlay: _playFromAudioService,
      onPause: pauseFromNotification,
      onStop: closePlayer,
      onNext: () => playNext(userInitiated: true),
      onPrevious: () => playPrevious(userInitiated: true),
      onSeek: (position) => seek(position, userInitiated: true),
      onRepeatMode: (mode) async => toggleRepeat(),
    );
    unawaited(_configureAudioSession());
    _initStreams();
    unawaited(_loadDownloadPaths());
    unawaited(_player.setVolume(1.0));
    unawaited(_player.setLoopMode(_repeatOne ? LoopMode.one : LoopMode.off));
  }

  // Configures the system audio session for background music playback and handles interruptions.
  // Automatically ducks volume to 40% during GPS announcements or pauses during phone calls.
  Future<void> _configureAudioSession() async {
    try {
      final session = await AudioSession.instance;
      // Set music audio session category (requests audio focus from the OS).
      await session.configure(const AudioSessionConfiguration.music());

      // Listen for interruptions like incoming phone calls or other apps playing audio.
      session.interruptionEventStream.listen((event) {
        if (event.begin) {
          switch (event.type) {
            case AudioInterruptionType.duck:
              // Lower volume temporarily so the user can hear notifications or GPS directions.
              _player.setVolume(0.4);
              break;
            case AudioInterruptionType.pause:
            case AudioInterruptionType.unknown:
              // Pause playback when another app claims exclusive audio focus (e.g., phone call).
              pauseFromNotification();
              break;
          }
        } else {
          // Interruption has finished; restore volume.
          switch (event.type) {
            case AudioInterruptionType.duck:
              _player.setVolume(1.0);
              break;
            case AudioInterruptionType.pause:
              break;
            case AudioInterruptionType.unknown:
              break;
          }
        }
      });

      // Activate audio session if audio is currently playing.
      if (_isPlaying) await session.setActive(true);
    } catch (e) {
      debugPrint('Audio session configuration failed: $e');
    }
  }

  // Returns true if this song has been downloaded and verified on disk.
  bool isDownloaded(Song song) => _downloadPaths.containsKey(_songKey(song));

  // Returns true if this song is currently downloading in the background.
  bool isDownloading(Song song) => _downloadingKeys.contains(_songKey(song));

  // Returns download progress as a fraction from 0.0 (0%) to 1.0 (100%).
  double downloadProgress(Song song) => _downloadProgress[_songKey(song)] ?? 0;

  // Returns true if this song is currently being exported to the user's public device Downloads directory.
  bool isExportingToDevice(Song song) =>
      _exportingKeys.contains(_songKey(song));

  // Updates the reference to the AccountProvider to keep user libraries and likes synchronized.
  void updateAccount(AccountProvider account) {
    _account = account;
  }

  // Scans disk to verify previously downloaded songs and populate the in-memory paths cache.
  Future<void> _loadDownloadPaths() async {
    final paths = await storage.getDownloadPaths();
    var changed = false;
    for (final entry in paths.entries) {
      // Verify the file still actually exists on the filesystem.
      if (await File(entry.value).exists()) {
        _downloadPaths[entry.key] = entry.value;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  // Subscribes to Just Audio reactive event streams to keep app UI synchronized with the audio engine.
  void _initStreams() {
    // 1. Playback position stream: throttled to 500ms intervals to prevent UI jank.
    _player.positionStream
        .throttleTime(const Duration(milliseconds: 500))
        .listen((position) {
      if (position > const Duration(seconds: 0)) {
        _lastValidPosition = position;
      }
      _position = position;
      // Mark that genuine audio has begun playing once past 2 seconds.
      if (position > const Duration(seconds: 2)) {
        _hasPlayedSomeAudio = true;
      }
      notifyListeners();
      // Check if playback is close enough to the end of the song to prepare auto-advance.
      _maybeAutoAdvanceFromPosition(position);
    });

    // 2. Duration stream: updates the total length of the active track once resolved by decoder.
    _player.durationStream.listen((duration) {
      if (duration != null && duration > Duration.zero) {
        _duration = duration;
        
        // If the song initially had 0 duration (e.g. from Home feed), update it.
        if (_currentSong != null && _currentSong!.duration == 0) {
          _currentSong = _currentSong!.copyWith(duration: duration.inSeconds);
          unawaited(_recordRecentlyPlayed(_currentSong!));
        }
        
        notifyListeners();
      }
    });

    // 3. Android audio session ID stream: re-links native equalizer/bass boost when audio track changes.
    _player.androidAudioSessionIdStream.listen((_) {
      unawaited(_syncAndroidAudioEffects(forceRecreate: true));
    });

    // 4. Current index stream: detects when Just Audio advances through playlist audio sources.
    _player.currentIndexStream.listen((index) {
      if (index == null ||
          index == _lastAudioSourceIndex ||
          index < 0 ||
          index >= _sourceSongs.length) {
        return;
      }
      _lastAudioSourceIndex = index;
      unawaited(_handleBackgroundQueueIndex(index));
    });

    // 5. Player state stream: tracks playing/paused status, buffering states, and track completion.
    _player.playerStateStream.listen((state) {
      var changed = false;
      // Handle playing vs paused transitions.
      if (_isPlaying != state.playing) {
        _isPlaying = state.playing;
        changed = true;
        // Keep device screen awake during active playback if needed.
        unawaited(WakelockPlus.toggle(enable: _isPlaying));
        // Keep Android audio effects in sync with playback state.
        unawaited(_syncAndroidAudioEffects(playingOverride: _isPlaying));
      }

      // Check whether loading spinner should be shown or temporarily suppressed (e.g. during seek).
      final suppressSeekLoading =
          DateTime.now().isBefore(_seekLoadingSuppressedUntil);
      final isBuffering = state.processingState == ProcessingState.buffering ||
          state.processingState == ProcessingState.loading;
      final sourceIsLoading = isBuffering && !suppressSeekLoading;
      final sourceIsReadyOrDone = state.processingState ==
              ProcessingState.ready ||
          (state.processingState == ProcessingState.completed && !_isLoading);

      // Transition to loading state.
      if (sourceIsLoading && !_isLoading) {
        _isLoading = true;
        changed = true;
        _startBufferingWatchdog();
      } else if (sourceIsReadyOrDone && _isLoading) {
        // Transition out of loading state.
        _isLoading = false;
        changed = true;
        _stopBufferingWatchdog();
      }

      // Reset track completion tracker once the new song becomes ready.
      if (state.processingState == ProcessingState.ready) {
        _completionHandledForKey = null;
      }

      // Handle song finish event when processing state reaches completed.
      if (state.processingState == ProcessingState.completed && !_isLoading) {
        changed = _handlePlaybackCompleted() || changed;
      }

      if (changed) notifyListeners();
    });

    // 6. Playback error stream: detects 403 Forbidden or network drops and attempts auto-recovery.
    _player.playbackEventStream.listen(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('Playback stream error: $error');
        // Force recovery if error is an expired stream URL (HTTP 403) or network failure.
        if (error.toString().contains('403') ||
            error.toString().contains('network')) {
          unawaited(_recoverFromPlaybackError(force: true));
        } else {
          unawaited(_recoverFromPlaybackError());
        }
      },
    );
  }

  // Starts a 12-second watchdog timer when buffering begins.
  // If audio remains stuck in a loading state after 12 seconds, automatically initiates recovery.
  void _startBufferingWatchdog() {
    _bufferingWatchdog?.cancel();
    if (!_isPlaying || _currentSong == null) return;
    _bufferingWatchdog = Timer(const Duration(seconds: 12), () {
      if (_isLoading && _isPlaying && !_recoveringPlaybackError) {
        debugPrint('Buffering watchdog triggered - attempting recovery');
        unawaited(_recoverFromPlaybackError(force: true));
      }
    });
  }

  // Cancels the buffering watchdog timer once playback resumes smoothly.
  void _stopBufferingWatchdog() {
    _bufferingWatchdog?.cancel();
    _bufferingWatchdog = null;
  }

  // Handles the event when a song completes playback.
  // Verifies if the song actually played real audio (to avoid treating immediate stream failures as finishes).
  // If repeat-one is active, restarts from beginning; otherwise advances to next track in queue.
  bool _handlePlaybackCompleted() {
    final song = _currentSong;
    if (song == null) return false;
    final completedKey = _songKey(song);
    // Guard: ignore if this track completion has already been handled.
    if (_completionHandledForKey == completedKey) return false;
    _completionHandledForKey = completedKey;

    debugPrint('Playback completed for: ${song.title}');

    // Detect if the song ended prematurely (e.g. stream URL broke immediately after starting).
    final playedRealAudio = _hasPlayedSomeAudio ||
        _position > const Duration(seconds: 2) ||
        _duration > const Duration(seconds: 3);
    if (!playedRealAudio && _duration > Duration.zero) {
      debugPrint('Song ended too quickly, possible stream failure.');
      _isPlaying = false;
      _isLoading = false;
      _error = PlayerError.streamUnavailable;
      notifyListeners();
      // Proceed to next song if repeat-one is not locking the player.
      if (!_repeatOne) _startAutoAdvance();
      return true;
    }

    // If repeat-one mode is active, loop the current song from beginning.
    if (_repeatOne) {
      unawaited(_player.seek(Duration.zero));
      _startPlayback();
      return false;
    }

    // Normal queue behavior: auto-advance to next song.
    _startAutoAdvance();
    return false;
  }

  // Secondary safety check: evaluates playback position to detect song ending.
  // Sometimes Just Audio's completed event fails to fire on certain stream formats;
  // this triggers auto-advance when remaining time drops below 600 milliseconds.
  void _maybeAutoAdvanceFromPosition(Duration position) {
    if (!_isPlaying ||
        _isLoading ||
        _repeatOne ||
        _autoAdvancing ||
        _currentSong == null ||
        _queue.isEmpty ||
        _duration <= const Duration(seconds: 4)) {
      return;
    }

    final remaining = _duration - position;
    // Trigger if remaining time is between 0 and 600ms, or past end within 5s.
    if (remaining > const Duration(milliseconds: 600) ||
        remaining < -const Duration(seconds: 5)) {
      return;
    }

    final currentKey = _songKey(_currentSong!);
    if (_completionHandledForKey == currentKey) {
      return;
    }

    debugPrint('Auto-advancing from position threshold');
    _startAutoAdvance();
  }

  // Initiates auto-advancing to the next track in the queue with a smooth 600ms transition.
  void _startAutoAdvance() {
    if (_autoAdvancing) return;
    _autoAdvancing = true;

    // Signal loading state to keep background foreground service alive during song transition.
    _isLoading = true;
    notifyListeners();

    // Slight delay allows current audio buffers and UI animations to settle smoothly.
    Future.delayed(const Duration(milliseconds: 600), () async {
      try {
        if (!_autoAdvancing) return;
        if (_queue.isEmpty) {
          await _stopPlaybackAtQueueBoundary();
          return;
        }
        await playNext(userInitiated: false);
      } finally {
        _autoAdvancing = false;
      }
    });
  }

  // The main method used across the app to start playing a selected song.
  // Handles queue adoption, cancellation of previous requests, loading state notifications,
  // resolving working audio stream candidates, recording history, and liking state.
  Future<void> playSong(Song song,
      {List<Song>? playlist,
      bool forceReload = false,
      bool userInitiated = true,
      Duration? initialPosition}) async {
    final account = _account;
    // Check if the requested song is already loaded and error-free.
    if (_currentSong != null &&
        _songKey(_currentSong!) == _songKey(song) &&
        _error == PlayerError.none &&
        !forceReload) {
      _adoptPlaylist(song, playlist);
      if (userInitiated) _markUserInteraction();
      // Pre-warm the next songs in the queue in the background.
      unawaited(_prefetchBackgroundQueue(_playRequestId, account: account));
      
      // If paused or idle, resume playback immediately.
      if (!_isPlaying && _player.processingState != ProcessingState.idle) {
        _startPlayback();
      }
      return;
    }

    // Increment request ID to cancel and ignore any previous pending play requests.
    final requestId = ++_playRequestId;
    try {
      await _player.stop(); // Stop audio engine synchronously to prevent overlapping sound
    } catch (_) {}

    // Reset playback tracking state.
    _completionHandledForKey = null;
    _currentSong = song;
    _hasPlayedSomeAudio = false;
    _error = PlayerError.none;
    _isLoading = true;
    _position = Duration.zero;
    _lastValidPosition = Duration.zero;
    _duration =
        song.duration > 0 ? Duration(seconds: song.duration) : Duration.zero;
    _adoptPlaylist(song, playlist);
    if (userInitiated) _markUserInteraction();
    notifyListeners();
    
    try {
      // Check local storage for liked status.
      _isLiked = await storage.isLiked(song.id);
      notifyListeners();

      // Find and play the first working audio stream candidate with a 35-second safety timeout.
      final playedSong =
          await _playFirstWorkingCandidate(song, requestId, account: account, initialPosition: initialPosition)
              .timeout(const Duration(seconds: 35), onTimeout: () => null);
      // Abort if another play request superseded this one while waiting.
      if (requestId != _playRequestId) return;
      if (playedSong == null) {
        _error = PlayerError.streamUnavailable;
        _isLoading = false;
        notifyListeners();
        return;
      }
      
      // Update _currentSong with playedSong, but preserve any newly discovered duration
      // in case the stream loaded and fired durationStream while we were waiting.
      final discoveredDuration = _duration.inSeconds;
      if (discoveredDuration > 0 && playedSong.duration == 0) {
        _currentSong = playedSong.copyWith(duration: discoveredDuration);
      } else {
        _currentSong = playedSong;
      }
      
      _isLiked = await storage.isLiked(_currentSong!.id);
      // Record song into listening history.
      await _recordRecentlyPlayed(_currentSong!);
    } catch (e) {
      if (requestId != _playRequestId) return;
      _error = PlayerError.networkError;
      debugPrint('Playback failed for ${song.title}: $e');
    } finally {
      if (requestId == _playRequestId) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  // Attempts automatic playback recovery when a stream drops or encounters HTTP 403 Forbidden.
  // Throttled to prevent recovery loops, clears cached stream URLs, and resumes from saved position.
  Future<void> _recoverFromPlaybackError({bool force = false}) async {
    if (_recoveringPlaybackError) return;
    final now = DateTime.now();
    // Throttle recovery attempts to once every 5 seconds unless forced.
    if (!force &&
        now.difference(_lastPlaybackRecoveryAt) < const Duration(seconds: 5)) {
      return;
    }
    _lastPlaybackRecoveryAt = now;
    _recoveringPlaybackError = true;
    // Remember current playback position so song resumes seamlessly where it left off.
    final savedPosition = _lastValidPosition > _position ? _lastValidPosition : _position;
    try {
      final song = _currentSong;
      if (song == null) return;
      debugPrint('Recovering playback for ${song.title} (force=$force)');
      // Invalidate possibly expired audio stream URL in the cache.
      ApiService.clearStreamCache(song.id, song.source);
      _isLoading = true;
      _error = PlayerError.none;
      notifyListeners();
      await playSong(song,
          playlist: _queue, forceReload: true, userInitiated: false, initialPosition: savedPosition);
    } catch (e) {
      _error = PlayerError.networkError;
      _isLoading = false;
      notifyListeners();
    } finally {
      _recoveringPlaybackError = false;
    }
  }

  // Updates the active playback queue and synchronizes the queue index to match the selected song.
  void _adoptPlaylist(Song song, List<Song>? playlist) {
    if (playlist != null && playlist.isNotEmpty) {
      _queue = List<Song>.from(playlist);
      _queueIndex = _queue.indexWhere(
          (item) => item.id == song.id && item.source == song.source);
      if (_queueIndex < 0) _queueIndex = 0;
    } else if (_queue.isEmpty) {
      _queue = [song];
      _queueIndex = 0;
    }
  }

  // Finds and plays the first working audio candidate for a given song.
  // Evaluates multiple fallback sources in order:
  // 1. Local downloaded file (instant offline playback).
  // 2. Direct streaming URLs from the song's primary source.
  // 3. Fallback YouTube Music searches matching artist and title.
  // 4. Broad multi-source search fallbacks if primary stream fails.
  Future<Song?> _playFirstWorkingCandidate(Song song, int requestId,
      {AccountProvider? account, Duration? initialPosition}) async {
    final tried = <String>{};
    final completer = Completer<Song?>();
    var finished = false;

    // Compares titles and artists fuzzily to ensure search fallback tracks actually match the requested song.
    bool isSimilar(Song candidate) {
      final targetTitle = _normalizeForComparison(song.title);
      final candidateTitle = _normalizeForComparison(candidate.title);
      if (candidateTitle.contains(targetTitle) ||
          targetTitle.contains(candidateTitle)) {
        return true;
      }
      final targetArtist = _normalizeForComparison(song.artist);
      final candidateArtist = _normalizeForComparison(candidate.artist);
      if (candidateArtist.contains(targetArtist) ||
          targetArtist.contains(candidateArtist)) {
        return true;
      }
      return false;
    }

    // Attempts to load and play a candidate song. Returns true if successful.
    Future<bool> tryCandidate(Song candidate,
        {bool strict = false, bool fastTimeout = false}) async {
      if (finished || requestId != _playRequestId) return false;
      final key = '${candidate.source}:${candidate.id}';
      if (tried.contains(key) || candidate.id.isEmpty) return false;
      tried.add(key);
      // If strict mode is enabled, verify title/artist similarity to avoid playing wrong song.
      if (strict && !isSimilar(candidate)) return false;
      try {
        // Step 1: Check if this candidate is downloaded locally on the device.
        final localPath = await _validDownloadPath(candidate);
        if (localPath != null) {
          if (finished || requestId != _playRequestId) return false;
          await _setAudioSourceAndPlay(
              candidate, _localAudioSourceFor(candidate, localPath), requestId,
              prefetchQueue: false, account: account, initialPosition: initialPosition);
          return true;
        }

        // Step 2: Fetch remote streaming URLs via ApiService.
        final urls =
            await ApiService.getStreamUrls(candidate.id, candidate.source)
                .timeout(fastTimeout
                    ? const Duration(seconds: 8)
                    : const Duration(seconds: 15));
        if (urls.isEmpty) return false;

        // Try each stream URL until one successfully loads and begins playing.
        for (final url in urls) {
          if (finished || requestId != _playRequestId) return false;
          try {
            final source =
                await _audioSourceFor(candidate, url, account: account);
            await _setAudioSourceAndPlay(candidate, source, requestId,
                prefetchQueue: true, account: account, initialPosition: initialPosition);
            return true;
          } catch (e) {
            if (requestId != _playRequestId) return false;
          }
        }
      } catch (e) {
        debugPrint('Candidate $key failed: $e');
      }
      return false;
    }

    // Attempt to play the exact requested song first.
    final success = await tryCandidate(song);
    if (success && requestId == _playRequestId) {
      finished = true;
      completer.complete(song);
      return completer.future;
    }
    if (requestId != _playRequestId) return null;

    // Fallback 1: For YouTube songs whose stream failed, search YouTube Music for matching track alternatives.
    if (song.source == 'youtube') {
      final fallbackQuery = '${song.title} ${song.artist}';
      try {
        final candidates =
            await ApiService.searchYoutubeMusic(fallbackQuery, limit: 3);
        for (final candidate in candidates) {
          if (finished || requestId != _playRequestId) break;
          final ok =
              await tryCandidate(candidate, strict: true, fastTimeout: true);
          if (ok) {
            finished = true;
            completer.complete(candidate);
            return completer.future;
          }
        }
      } catch (_) {}
    }

    // Fallback 2: Broad general search across all available providers.
    if (!finished && requestId == _playRequestId) {
      try {
        final broadCandidates =
            await ApiService.search('${song.title} ${song.artist}', limit: 3);
        for (final candidate in broadCandidates) {
          if (finished || requestId != _playRequestId) break;
          final ok =
              await tryCandidate(candidate, strict: true, fastTimeout: true);
          if (ok) {
            finished = true;
            completer.complete(candidate);
            return completer.future;
          }
        }
      } catch (_) {}
    }

    if (!finished && requestId == _playRequestId) completer.complete(null);
    return completer.future
        .timeout(const Duration(seconds: 50), onTimeout: () => null);
  }

  // Normalizes text by lowercasing and removing all non-alphanumeric characters for fuzzy matching.
  String _normalizeForComparison(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');

  // Synchronizes player state when Just Audio automatically transitions to another track index.
  Future<void> _handleBackgroundQueueIndex(int index) async {
    final song = _sourceSongs[index];
    _currentSong = song;
    _error = PlayerError.none;
    _position = Duration.zero;
    final matchingQueueIndex = _queue
        .indexWhere((item) => item.id == song.id && item.source == song.source);
    if (matchingQueueIndex >= 0) _queueIndex = matchingQueueIndex;
    notifyListeners();
    _isLiked = await storage.isLiked(song.id);
    await _recordRecentlyPlayed(song);
    notifyListeners();
    // Pre-warm the next songs in queue.
    unawaited(_prefetchBackgroundQueue(_playRequestId, account: _account));
  }

  // Configures the Just Audio player engine with the resolved AudioSource and starts audio output.
  Future<void> _setAudioSourceAndPlay(
      Song song, AudioSource audioSource, int requestId,
      {required bool prefetchQueue, AccountProvider? account, Duration? initialPosition}) async {
    if (requestId != _playRequestId) return;
    
    // Store current active source track.
    _sourceSongs
      ..clear()
      ..add(song);
    _sourceKeys
      ..clear()
      ..add(_songKey(song));
    _lastAudioSourceIndex = 0;
    
    if (requestId != _playRequestId) return;
    
    // Load audio stream into the player engine with timeout safeguard.
    await _player
        .setAudioSource(audioSource, initialPosition: initialPosition)
        .timeout(prefetchQueue ? _streamLoadTimeout : _localLoadTimeout);
        
    if (requestId != _playRequestId) return;
    
    // Apply pitch and speed configurations.
    await _applyTempo();
    // Re-initialize Android equalizer and sound effects with new audio session.
    await _syncAndroidAudioEffects(forceRecreate: true);
    if (prefetchQueue) {
      unawaited(_prefetchBackgroundQueue(requestId, account: account));
    }
    // Start audio output if request is still current.
    if (requestId == _playRequestId) _startPlayback();
    _scheduleAndroidEffectResync();
  }

  // Wraps a remote stream URL in an AudioSource with MediaItem metadata for lock screen and notification controls.
  Future<AudioSource> _audioSourceFor(Song song, String streamUrl,
      {AccountProvider? account}) async {
    final headers = await _headersFor(song, account: account);
    return AudioSource.uri(Uri.parse(streamUrl),
        headers: headers,
        tag: MediaItem(
            id: '${song.source}:${song.id}',
            album: song.album,
            title: song.title,
            artist: song.artist,
            artUri: song.thumbnailUrl.isNotEmpty
                ? Uri.tryParse(song.thumbnailUrl)
                : null));
  }

  // Wraps a local downloaded audio file path in an AudioSource for offline playback.
  AudioSource _localAudioSourceFor(Song song, String localPath) =>
      AudioSource.uri(Uri.file(localPath),
          tag: MediaItem(
              id: '${song.source}:${song.id}',
              album: song.album,
              title: song.title,
              artist: song.artist,
              artUri: song.thumbnailUrl.isNotEmpty
                  ? Uri.tryParse(song.thumbnailUrl)
                  : null));

  // Pre-fetches streaming URLs for upcoming tracks in the queue ahead of time.
  // When the user taps Next, the next song begins playing instantaneously without buffering delay.
  Future<void> _prefetchBackgroundQueue(int requestId,
      {AccountProvider? account}) async {
    if (requestId != _playRequestId) return;
    final start = _queueIndex + 1;
    if (start >= _queue.length) return;

    // Fast stage: pre-fetch the next 3 songs immediately with small staggered delays.
    for (var i = start; i < math.min(_queue.length, start + 3); i++) {
      if (requestId != _playRequestId) return;
      final song = _queue[i];
      if (await _validDownloadPath(song) != null) continue;
      try {
        unawaited(ApiService.getStreamUrls(song.id, song.source));
      } catch (_) {}
      // Small 400ms delay between rapid-fire requests to prevent hitting rate limits.
      await Future.delayed(const Duration(milliseconds: 400));
    }

    // Lazy stage: warm remaining songs (up to 5 ahead) more slowly.
    for (var i = start + 3; i < math.min(_queue.length, start + 5); i++) {
      if (requestId != _playRequestId) return;
      final song = _queue[i];
      if (await _validDownloadPath(song) != null) continue;
      try {
        unawaited(ApiService.getStreamUrls(song.id, song.source));
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 1200));
    }
  }

  // Generates composite lookup key for a song.
  String _songKey(Song song) => '${song.source}:${song.id}';

  // Verifies whether a song exists on local storage as a valid downloaded file.
  Future<String?> _validDownloadPath(Song song) async {
    final key = _songKey(song);
    var path = _downloadPaths[key] ?? await storage.getDownloadPath(song);
    if (path == null || path.isEmpty) return null;
    if (await File(path).exists()) {
      _downloadPaths[key] = path;
      return path;
    }
    // File was removed from disk; remove cached reference.
    _downloadPaths.remove(key);
    await storage.removeDownloadedSong(song);
    notifyListeners();
    return null;
  }

  // Returns effective pitch: if pitch control is disabled, pitch naturally follows playback speed.
  double get _effectivePitch => _pitchEnabled ? _pitch : _speed;

  // Applies active speed and pitch configurations to the Just Audio player.
  Future<void> _applyTempo() async {
    await _player.setSpeed(_speed);
    await _player.setPitch(_effectivePitch);
  }

  // Generates required HTTP request headers (like cookies, user-agents, or referrers) for streaming.
  Future<Map<String, String>?> _headersFor(Song song,
      {AccountProvider? account}) async {
    final baseHeaders = ApiService.streamHeaders(song.source, song.id) ?? {};
    if (song.source == 'youtube') {
      return baseHeaders.isEmpty ? null : baseHeaders;
    }
    // Add user's authenticated Google cookies if playing personal YouTube Music tracks.
    if (account != null && account.isSignedIn) {
      final authHeaders = await account.getAuthHeaders();
      if (authHeaders != null) return {...baseHeaders, ...authHeaders};
    }
    return baseHeaders.isEmpty ? null : baseHeaders;
  }

  // Toggles between playing and paused states.
  // If the player was idle or finished, reloads the current track.
  Future<void> togglePlayPause() async {
    _markUserInteraction();
    if (_isLoading) {
      return;
    }

    if (_isPlaying) {
      pauseFromNotification();
    } else {
      final song = _currentSong;
      if (song != null &&
          (_player.processingState == ProcessingState.idle ||
              _player.processingState == ProcessingState.completed)) {
        await playSong(song, playlist: _queue, forceReload: true);
        return;
      }
      _startPlayback();
    }
  }

  // Internal play callback triggered by audio_service when user hits play from system notification.
  Future<void> _playFromAudioService() async {
    _markUserInteraction();
    if (_isLoading) {
      return;
    }
    final song = _currentSong;
    if (song != null &&
        (_player.processingState == ProcessingState.idle ||
            _player.processingState == ProcessingState.completed)) {
      await playSong(song, playlist: _queue, forceReload: true);
      return;
    }
    _startPlayback();
  }

  // Pauses playback from system notification or lock screen widget.
  Future<void> pauseFromNotification() async {
    _markUserInteraction();
    _isPlaying = false;
    notifyListeners();
    unawaited(_syncAndroidAudioEffects(playingOverride: false));
    unawaited(_player.pause());
  }

  // Stops audio playback completely, clears the active queue, and cleans up native effects.
  Future<void> closePlayer() async {
    _playRequestId++;
    _completionHandledForKey = null;
    _autoAdvancing = false;
    _currentSong = null;
    _queue = [];
    _queueIndex = 0;
    _isPlaying = false;
    _isLoading = false;
    _position = Duration.zero;
    _duration = Duration.zero;
    _error = PlayerError.none;
    _sourceSongs.clear();
    _sourceKeys.clear();
    notifyListeners();
    await _player.stop();
    // Release native Android audio effects (equalizer and bass boost session).
    if (defaultTargetPlatform == TargetPlatform.android) {
      unawaited(_effectsChannel.invokeMethod<void>('releaseAudioEffects'));
    }
  }

  // Inserts a song into the queue to play immediately after the current song.
  void insertNext(Song song) {
    if (_queue.isEmpty) {
      playSong(song);
    } else {
      _queue.insert(_queueIndex + 1, song);
      notifyListeners();
    }
  }

  // Advances playback to the next song in the queue.
  // Supports shuffle mode and automatically skips unplayable tracks during background auto-advance.
  Future<void> playNext({bool userInitiated = true}) async {
    if (userInitiated) {
      _markUserInteraction();
    }
    if (_queue.isEmpty) {
      return;
    }
    // Handle single-song queues: repeat or stop at boundary.
    if (_queue.length == 1) {
      if (userInitiated) {
        await _playQueueIndex(0, userInitiated: userInitiated);
      } else {
        await _stopPlaybackAtQueueBoundary();
      }
      return;
    }
    // Track attempted song indices to avoid infinite loops if multiple tracks fail.
    final attempted = <int>{};
    var nextIndex = _nextQueueIndex(excluded: attempted);
    while (nextIndex != null && attempted.length < _queue.length) {
      attempted.add(nextIndex);
      final played =
          await _playQueueIndex(nextIndex, userInitiated: userInitiated);
      // Stop looping if the song started playing successfully, or if user explicitly triggered it.
      if (played || userInitiated) {
        return;
      }
      nextIndex = _nextQueueIndex(excluded: attempted);
    }
    await _stopPlaybackAtQueueBoundary();
  }

  // Calculates the next queue index based on shuffle mode and excluded (already attempted) indices.
  int? _nextQueueIndex({Set<int> excluded = const {}}) {
    if (_queue.isEmpty || _queue.length == 1) return null;
    final current = _queueIndex.clamp(0, _queue.length - 1).toInt();
    // Shuffle mode: pick pseudo-randomly from remaining unplayed songs in queue.
    if (_shuffleOn) {
      final remaining = <int>[
        for (var i = 0; i < _queue.length; i++)
          if (i != current && !excluded.contains(i)) i
      ];
      if (remaining.isEmpty) return null;
      return remaining[
          DateTime.now().millisecondsSinceEpoch % remaining.length];
    }
    // Normal mode: cycle sequentially to the next track.
    for (var offset = 1; offset <= _queue.length; offset++) {
      final next = (current + offset) % _queue.length;
      if (!excluded.contains(next)) return next;
    }
    return null;
  }

  // Safely stops playback when reaching the boundary end of the queue.
  Future<void> _stopPlaybackAtQueueBoundary() async {
    _playRequestId++;
    _completionHandledForKey = null;
    await _player.pause();
    _isPlaying = false;
    _isLoading = false;
    _error = PlayerError.none;
    notifyListeners();
  }

  // Skips back to the previous track in the queue, or restarts the song from 0:00 if already on the first track.
  Future<void> playPrevious({bool userInitiated = true}) async {
    if (userInitiated) _markUserInteraction();
    if (_queue.isEmpty) return;
    if (_queueIndex <= 0) {
      await seek(Duration.zero);
      return;
    }
    await _playQueueIndex(_queueIndex - 1, userInitiated: userInitiated);
  }

  // Plays the song at the specified queue index, clamping within queue bounds.
  Future<bool> _playQueueIndex(int index, {required bool userInitiated}) async {
    if (_queue.isEmpty) return false;
    final clamped = index.clamp(0, _queue.length - 1).toInt();
    _queueIndex = clamped;
    await playSong(_queue[clamped],
        playlist: _queue, forceReload: true, userInitiated: userInitiated);
    return _currentSong != null && _error == PlayerError.none;
  }

  // Records a song to the local listening history and bumps the revision counter to update UI widgets.
  Future<void> _recordRecentlyPlayed(Song song) async {
    await storage.addRecentlyPlayed(song);
    _recentRevision++;
    notifyListeners();
  }

  // Removes a song from recently played history.
  Future<void> removeFromRecentlyPlayed(Song song) async {
    await storage.removeRecentlyPlayed(song);
    _recentRevision++;
    notifyListeners();
  }

  // Seeks to a specific timestamp in the current song.
  // Suppresses loading spinners for 900ms to allow smooth user scrubbing without flickering.
  Future<void> seek(Duration position, {bool userInitiated = true}) async {
    if (userInitiated) _markUserInteraction();
    final clamped = _clampToDuration(position);
    _position = clamped;
    // Suppress loading spinners briefly during manual seeking.
    _seekLoadingSuppressedUntil =
        DateTime.now().add(const Duration(milliseconds: 900));
    notifyListeners();
    await _player.seek(clamped);
  }

  // Restricts a Duration to remain between zero and the maximum track duration.
  Duration _clampToDuration(Duration value) {
    if (value.isNegative) return Duration.zero;
    if (_duration > Duration.zero && value > _duration) return _duration;
    return value;
  }

  // Sets playback speed multiplier (clamped between 0.5x half speed and 2.0x double speed).
  Future<void> setSpeed(double value) async {
    _markUserInteraction();
    _speed = value.clamp(0.5, 2.0).toDouble();
    // If independent pitch is disabled, pitch shifts together with speed like an analog tape deck.
    if (!_pitchEnabled) _pitch = _speed;
    await _applyTempo();
    notifyListeners();
  }

  // Sets the independent pitch multiplier (clamped between 0.5x and 2.0x).
  Future<void> setPitch(double value) async {
    _markUserInteraction();
    _pitch = value.clamp(0.5, 2.0).toDouble();
    if (_pitchEnabled) await _applyTempo();
    notifyListeners();
  }

  // Enables or disables independent pitch control.
  // When disabled, pitch automatically mirrors speed.
  Future<void> setPitchEnabled(bool enabled) async {
    _markUserInteraction();
    _pitchEnabled = enabled;
    if (!enabled) _pitch = _speed;
    await _applyTempo();
    notifyListeners();
  }

  // Starts audio playback in Just Audio, engages Android effects, and attaches error listeners.
  void _startPlayback() {
    _isPlaying = true;
    unawaited(_syncAndroidAudioEffects(playingOverride: true));
    unawaited(_player.play().catchError((Object error, StackTrace stackTrace) {
      debugPrint('Playback start failed: $error');
      unawaited(_recoverFromPlaybackError());
    }));
  }

  // Schedules delayed syncs for Android audio effects after starting a track
  // to ensure native audio session drivers have fully attached before applying equalizer.
  void _scheduleAndroidEffectResync() {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    Future<void>.delayed(const Duration(milliseconds: 250), () async {
      if (_currentSong != null) await _syncAndroidAudioEffects();
    });
    Future<void>.delayed(const Duration(milliseconds: 900), () async {
      if (_currentSong != null) await _syncAndroidAudioEffects();
    });
  }

  // Prepares the audio engine for interactive turntable scratching.
  // Suppresses loading spinners for 1.4s so the UI feels responsive like a real vinyl record.
  Future<void> beginScratch() async {
    _markUserInteraction();
    _seekLoadingSuppressedUntil =
        DateTime.now().add(const Duration(milliseconds: 1400));
    _lastScratchSpeedSyncAt = DateTime.fromMillisecondsSinceEpoch(0);
  }

  // Simulates vinyl scratching physics as the user rotates their finger around the disc.
  // Dynamically alters playback speed and pitch based on rotation speed and direction (clockwise vs counterclockwise).
  Future<void> scratchTo(Duration position, double deltaRadians) async {
    final clamped = _clampToDuration(position);
    _position = clamped;
    _seekLoadingSuppressedUntil =
        DateTime.now().add(const Duration(milliseconds: 1400));
    notifyListeners();
    final now = DateTime.now();
    // Throttle speed/pitch adjustments to once every 90ms to maintain audio stability.
    if (_isPlaying &&
        now.difference(_lastScratchSpeedSyncAt) >
            const Duration(milliseconds: 90)) {
      _lastScratchSpeedSyncAt = now;
      final intensity = (deltaRadians.abs() * 7).clamp(0.0, 1.0).toDouble();
      // Forward scratch vs backward scratch speed calculation.
      final shuttleSpeed = deltaRadians >= 0
          ? (0.9 + intensity * 1.1).clamp(0.5, 2.0).toDouble()
          : (0.5 + intensity * 0.8).clamp(0.5, 2.0).toDouble();
      await _player.setSpeed(shuttleSpeed);
      await _player.setPitch(_pitchEnabled ? _pitch : shuttleSpeed);
    }
    await _player.seek(clamped);
  }

  // Concludes a vinyl scratch gesture when the user lifts their finger.
  // Resets audio speed and pitch back to the user's configured tempo and resumes playback.
  Future<void> endScratch(Duration position) async {
    await seek(position, userInitiated: false);
    await _applyTempo();
    if (_isPlaying) _startPlayback();
  }

  // Sets bass boost intensity level (clamped between 0.0 off and 1.0 maximum).
  // Sends updated values to native Android audio effects via platform channel.
  Future<void> setBass(double value) async {
    _markUserInteraction();
    _bass = value.clamp(0.0, 1.0).toDouble();
    await _syncAndroidAudioEffects();
    notifyListeners();
  }

  // Sets environmental reverb level (clamped between 0.0 dry and 1.0 wet).
  // Sends updated values to native Android audio effects via platform channel.
  Future<void> setReverb(double value) async {
    _markUserInteraction();
    _reverb = value.clamp(0.0, 1.0).toDouble();
    await _syncAndroidAudioEffects();
    notifyListeners();
  }

  // Downloads a song into the app's private offline directory.
  // Tracks progress and notifies UI at throttled intervals (every 140ms) to keep UI smooth.
  Future<bool> downloadSong(Song song) async {
    final key = _songKey(song);
    // Return early if already downloaded or currently in progress.
    if (_downloadPaths.containsKey(key) || _downloadingKeys.contains(key)) {
      return _downloadPaths.containsKey(key);
    }
    _downloadingKeys.add(key);
    _downloadProgress[key] = 0;
    notifyListeners();
    var lastProgressNotify = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      final localPath =
          await _downloadService.downloadSong(song, onProgress: (progress) {
        _downloadProgress[key] = progress;
        final now = DateTime.now();
        // Throttle UI rebuilds during downloading to reduce battery and CPU usage.
        if (progress >= 1 ||
            now.difference(lastProgressNotify) >
                const Duration(milliseconds: 140)) {
          lastProgressNotify = now;
          notifyListeners();
        }
      });
      _downloadPaths[key] = localPath;
      // Record download path in storage database.
      await storage.saveDownloadedSong(song, localPath);
      return true;
    } catch (e) {
      debugPrint('Download failed for ${song.title}: $e');
      return false;
    } finally {
      _downloadingKeys.remove(key);
      _downloadProgress.remove(key);
      notifyListeners();
    }
  }

  // Exports a song to the user's public device Downloads directory.
  // When applyEffects is true, renders audio with active bass, reverb, speed, and pitch applied.
  Future<String?> downloadToDevice(Song song,
      {bool applyEffects = false}) async {
    final key = _songKey(song);
    if (_exportingKeys.contains(key)) {
      return null;
    }
    _exportingKeys.add(key);
    notifyListeners();
    try {
      // Ensure the song has been downloaded locally first.
      var localPath = await _validDownloadPath(song);
      if (localPath == null) {
        final downloaded = await downloadSong(song);
        if (!downloaded) {
          return null;
        }
        localPath = await _validDownloadPath(song);
      }
      if (localPath == null) {
        return null;
      }
      final sourcePath = localPath;
      var fileName = _deviceFileName(song, sourcePath);
      // Append '_applied' suffix to filename if exported with custom sound effects.
      if (applyEffects) {
        final nameParts = fileName.split('.');
        if (nameParts.length > 1) {
          final ext = nameParts.removeLast();
          fileName = '${nameParts.join('.')}_applied.$ext';
        } else {
          fileName = '${fileName}_applied';
        }
      }
      // On Android, use the native files channel to insert the track into MediaStore Downloads.
      if (defaultTargetPlatform == TargetPlatform.android) {
        return await _filesChannel.invokeMethod<String>('saveToDownloads', {
          'sourcePath': sourcePath,
          'displayName': fileName,
          'mimeType': _mimeTypeFor(fileName),
          'applyEffects': applyEffects,
          'bass': _bass,
          'reverb': _reverb,
          'speed': _speed,
          'pitch': _effectivePitch,
        });
      }
      // On Desktop (Windows/macOS/Linux), copy file directly to user's Downloads folder.
      final downloadsDir = await _bestDownloadsDirectory();
      if (downloadsDir == null) {
        return sourcePath;
      }
      final exported =
          File('${downloadsDir.path}${Platform.pathSeparator}$fileName');
      await File(sourcePath).copy(exported.path);
      return exported.path;
    } catch (e) {
      debugPrint('Device download failed for ${song.title}: $e');
      return null;
    } finally {
      _exportingKeys.remove(key);
      notifyListeners();
    }
  }

  // Removes a downloaded song from the offline cache and deletes its record in storage.
  Future<void> removeDownload(Song song) async {
    final key = _songKey(song);
    _downloadPaths.remove(key);
    _downloadProgress.remove(key);
    _downloadingKeys.remove(key);
    await storage.removeDownloadedSong(song);
    notifyListeners();
  }

  // Synchronizes equalizer, bass, and reverb settings with the native Android audio session.
  // Includes a retry mechanism if the native audio session ID has not finished initializing.
  Future<void> _syncAndroidAudioEffects(
      {bool forceRecreate = false, bool? playingOverride}) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    final sessionId = _player.androidAudioSessionId;
    // If the audio session ID isn't available yet, retry after 300ms.
    if (sessionId == null || sessionId <= 0) {
      Future.delayed(const Duration(milliseconds: 300), () async {
        final retrySessionId = _player.androidAudioSessionId;
        if (retrySessionId != null && retrySessionId > 0) {
          await _syncEffectsWithId(
            retrySessionId,
            forceRecreate: forceRecreate,
            playingOverride: playingOverride,
          );
        }
      });
      return;
    }
    await _syncEffectsWithId(
      sessionId,
      forceRecreate: forceRecreate,
      playingOverride: playingOverride,
    );
  }

  // Invokes the platform channel method 'setAudioEffects' to configure Android Equalizer and BassBoost.
  Future<void> _syncEffectsWithId(int sessionId,
      {bool forceRecreate = false, bool? playingOverride}) async {
    try {
      final result = await _effectsChannel
          .invokeMethod<Map<dynamic, dynamic>>('setAudioEffects', {
        'sessionId': sessionId,
        'bass': _bass,
        'reverb': _reverb,
        'forceRecreate': forceRecreate,
        'playing': playingOverride ?? _isPlaying,
      });
      debugPrint('Audio effects sync result: $result');
    } catch (e) {
      debugPrint('Android audio effects unavailable: $e');
    }
  }

  // Public helper to inform the player that the user touched or interacted with controls.
  void registerUserInteraction() {
    _markUserInteraction();
  }

  // Resets track completion markers so manual user actions take immediate priority over auto-advance.
  void _markUserInteraction() {
    _completionHandledForKey = null;
  }

  // Toggles shuffle mode on or off and updates UI listeners.
  void toggleShuffle() {
    _markUserInteraction();
    _shuffleOn = !_shuffleOn;
    notifyListeners();
  }

  // Toggles repeat-one mode on or off. Updates Just Audio loop mode accordingly.
  void toggleRepeat() {
    _markUserInteraction();
    _repeatOne = !_repeatOne;
    unawaited(_player.setLoopMode(_repeatOne ? LoopMode.one : LoopMode.off));
    notifyListeners();
  }

  // Toggles the liked/favorite status of the currently playing song.
  // Updates local storage and immediately syncs the like/unlike rating to YouTube Music if logged in.
  Future<void> toggleLike({AccountProvider? account}) async {
    _markUserInteraction();
    final song = _currentSong;
    if (song == null) return;
    final actualAccount = account ?? _account;
    
    final currentState = isLiked;
    final newState = !currentState;
    
    // Save to device local storage.
    final localState = await storage.isLiked(song.id);
    if (localState != newState) {
      await storage.toggleLike(song);
    }
    
    _isLiked = newState;
    _recentRevision++;
    notifyListeners();

    // Sync to user's remote YouTube Music account if signed in.
    if (actualAccount != null) {
      actualAccount.toggleLocalLikedState(song, newState);
      if (actualAccount.isSignedIn && actualAccount.youtubeAuthorized) {
        final headers = await actualAccount.getAuthHeaders();
        if (headers != null) {
          unawaited(YoutubeAccountService()
              .rateSong(headers, song.id, newState ? 'like' : 'none'));
        }
      }
    }
  }

  // Overrides notifyListeners to automatically publish state changes to the system notification.
  @override
  void notifyListeners() {
    _publishAudioServiceState();
    super.notifyListeners();
  }

  // Pushes updated player state (title, artist, album art, position, controls) to the system notification and lockscreen.
  void _publishAudioServiceState() {
    try {
      _audioHandler.publish(
        currentSong: _currentSong,
        songs: _queue,
        queueIndex: _queueIndex,
        playing: _isPlaying,
        loading: _isLoading,
        position: _position,
        duration: _duration,
        speed: _speed,
        shuffleOn: _shuffleOn,
        repeatOne: _repeatOne,
        hasError: _error != PlayerError.none,
      );
    } catch (e) {
      debugPrint('Audio service state publish failed: $e');
    }
  }

  // Disposes the player instance and releases native Android audio effects when the provider is destroyed.
  @override
  void dispose() {
    if (defaultTargetPlatform == TargetPlatform.android) {
      unawaited(_effectsChannel.invokeMethod<void>('releaseAudioEffects'));
    }
    _player.dispose();
    super.dispose();
  }

  // Resolves the standard user Downloads directory on desktop operating systems (Windows/macOS/Linux).
  Future<Directory?> _bestDownloadsDirectory() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      final home =
          Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
      if (home != null && home.isNotEmpty) {
        final directory = Directory('$home${Platform.pathSeparator}Downloads');
        if (await directory.exists()) return directory;
      }
    }
    return null;
  }

  // Sanitizes track title and artist into a clean, filesystem-safe filename for export.
  String _deviceFileName(Song song, String localPath) {
    final dot = localPath.lastIndexOf('.');
    final extension = dot >= 0 ? localPath.substring(dot) : '.m4a';
    final raw = '${song.title} - ${song.artist}';
    // Replace illegal characters like < > : " / \ | ? * with underscores.
    final name = raw
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    // Truncate overly long file names to 90 characters to avoid filesystem errors.
    final capped = name.length > 90 ? name.substring(0, 90).trim() : name;
    return '${capped.isEmpty ? song.id : capped}$extension';
  }

  // Maps audio file extensions to their corresponding standard MIME types.
  String _mimeTypeFor(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.mp3')) {
      return 'audio/mpeg';
    }
    if (lower.endsWith('.webm')) {
      return 'audio/webm';
    }
    if (lower.endsWith('.mp4')) {
      return 'video/mp4';
    }
    if (lower.endsWith('.m4a')) {
      return 'audio/mp4';
    }
    return 'audio/*';
  }
}
