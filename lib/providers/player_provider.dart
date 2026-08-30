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

enum PlayerError { none, streamUnavailable, networkError }

class PlayerProvider extends ChangeNotifier {
  // Lower timeout so failed URLs fail fast instead of hanging for 15s.
  static const Duration _streamLoadTimeout = Duration(seconds: 10);
  static const Duration _localLoadTimeout = Duration(seconds: 8);

  static const MethodChannel _effectsChannel =
      MethodChannel('musico/audio_effects');
  static const MethodChannel _filesChannel =
      MethodChannel('musico/device_files');

  final AudioPlayer _player = AudioPlayer(
    audioLoadConfiguration: const AudioLoadConfiguration(
      androidLoadControl: AndroidLoadControl(
        // Start playback after buffering only 500ms — same as Spotify/YT Music.
        // The player will continue buffering in the background while playing.
        minBufferDuration: Duration(seconds: 15),
        maxBufferDuration: Duration(seconds: 90),
        bufferForPlaybackDuration: Duration(milliseconds: 500),
        bufferForPlaybackAfterRebufferDuration: Duration(milliseconds: 1500),
        prioritizeTimeOverSizeThresholds: true,
        backBufferDuration: Duration(seconds: 30),
      ),
    ),
  );
  final StorageService storage = StorageService();
  final DownloadService _downloadService = DownloadService();
  final MusicoAudioHandler _audioHandler;

  Song? _currentSong;
  List<Song> _queue = [];
  int _queueIndex = 0;
  bool _isPlaying = false;
  bool _isLoading = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  PlayerError _error = PlayerError.none;
  double _speed = 1.0;
  double _pitch = 1.0;
  double _bass = 0.0;
  double _reverb = 0.0;
  bool _pitchEnabled = false;
  bool _shuffleOn = false;
  bool _repeatOne = false;
  bool _isLiked = false;
  bool _autoAdvancing = false;
  AccountProvider? _account;
  final List<Song> _sourceSongs = [];
  final Set<String> _sourceKeys = {};
  final Map<String, String> _downloadPaths = {};
  final Set<String> _downloadingKeys = {};
  final Map<String, double> _downloadProgress = {};
  final Set<String> _exportingKeys = {};
  int _recentRevision = 0;
  int? _lastAudioSourceIndex;
  int _playRequestId = 0;
  String? _completionHandledForKey;
  DateTime _seekLoadingSuppressedUntil = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastScratchSpeedSyncAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _recoveringPlaybackError = false;
  DateTime _lastPlaybackRecoveryAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _bufferingWatchdog;
  bool _hasPlayedSomeAudio = false;

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
  bool get isLiked => _isLiked;
  AudioPlayer get player => _player;
  int get recentRevision => _recentRevision;

  PlayerProvider({required MusicoAudioHandler audioHandler})
      : _audioHandler = audioHandler {
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

  Future<void> _configureAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());

      session.interruptionEventStream.listen((event) {
        if (event.begin) {
          switch (event.type) {
            case AudioInterruptionType.duck:
              _player.setVolume(0.4);
              break;
            case AudioInterruptionType.pause:
            case AudioInterruptionType.unknown:
              pauseFromNotification();
              break;
          }
        } else {
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

      if (_isPlaying) await session.setActive(true);
    } catch (e) {
      debugPrint('Audio session configuration failed: $e');
    }
  }

  bool isDownloaded(Song song) => _downloadPaths.containsKey(_songKey(song));
  bool isDownloading(Song song) => _downloadingKeys.contains(_songKey(song));
  double downloadProgress(Song song) => _downloadProgress[_songKey(song)] ?? 0;
  bool isExportingToDevice(Song song) =>
      _exportingKeys.contains(_songKey(song));

  void updateAccount(AccountProvider account) {
    _account = account;
  }

  Future<void> _loadDownloadPaths() async {
    final paths = await storage.getDownloadPaths();
    var changed = false;
    for (final entry in paths.entries) {
      if (await File(entry.value).exists()) {
        _downloadPaths[entry.key] = entry.value;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  void _initStreams() {
    _player.positionStream
        .throttleTime(const Duration(milliseconds: 500))
        .listen((position) {
      _position = position;
      if (position > const Duration(seconds: 2)) {
        _hasPlayedSomeAudio = true;
      }
      notifyListeners();
      _maybeAutoAdvanceFromPosition(position);
    });

    _player.durationStream.listen((duration) {
      if (duration != null && duration > Duration.zero) {
        _duration = duration;
        notifyListeners();
      }
    });

    _player.androidAudioSessionIdStream.listen((_) {
      unawaited(_syncAndroidAudioEffects(forceRecreate: true));
    });

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

    _player.playerStateStream.listen((state) {
      var changed = false;
      if (_isPlaying != state.playing) {
        _isPlaying = state.playing;
        changed = true;
        unawaited(WakelockPlus.toggle(enable: _isPlaying));
        unawaited(_syncAndroidAudioEffects(playingOverride: _isPlaying));
      }

      final suppressSeekLoading =
          DateTime.now().isBefore(_seekLoadingSuppressedUntil);
      final isBuffering = state.processingState == ProcessingState.buffering ||
          state.processingState == ProcessingState.loading;
      final sourceIsLoading = isBuffering && !suppressSeekLoading;
      final sourceIsReadyOrDone = state.processingState ==
              ProcessingState.ready ||
          (state.processingState == ProcessingState.completed && !_isLoading);

      if (sourceIsLoading && !_isLoading) {
        _isLoading = true;
        changed = true;
        _startBufferingWatchdog();
      } else if (sourceIsReadyOrDone && _isLoading) {
        _isLoading = false;
        changed = true;
        _stopBufferingWatchdog();
      }

      // Reset completion tracker when song becomes ready
      if (state.processingState == ProcessingState.ready) {
        _completionHandledForKey = null;
      }

      if (state.processingState == ProcessingState.completed && !_isLoading) {
        changed = _handlePlaybackCompleted() || changed;
      }

      if (changed) notifyListeners();
    });

    _player.playbackEventStream.listen(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('Playback stream error: $error');
        if (error.toString().contains('403') ||
            error.toString().contains('network')) {
          unawaited(_recoverFromPlaybackError(force: true));
        } else {
          unawaited(_recoverFromPlaybackError());
        }
      },
    );
  }

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

  void _stopBufferingWatchdog() {
    _bufferingWatchdog?.cancel();
    _bufferingWatchdog = null;
  }

  bool _handlePlaybackCompleted() {
    final song = _currentSong;
    if (song == null) return false;
    final completedKey = _songKey(song);
    if (_completionHandledForKey == completedKey) return false;
    _completionHandledForKey = completedKey;

    debugPrint('Playback completed for: ${song.title}');

    // If it was a very short play, it might be a stream error that just-audio
    // interpreted as completion (common for some direct links)
    final playedRealAudio = _hasPlayedSomeAudio ||
        _position > const Duration(seconds: 2) ||
        _duration > const Duration(seconds: 3);
    if (!playedRealAudio && _duration > Duration.zero) {
      debugPrint('Song ended too quickly, possible stream failure.');
      _isPlaying = false;
      _isLoading = false;
      _error = PlayerError.streamUnavailable;
      notifyListeners();
      // Try next song anyway if auto-advance is on
      if (!_repeatOne) _startAutoAdvance();
      return true;
    }

    if (_repeatOne) {
      unawaited(_player.seek(Duration.zero));
      _startPlayback();
      return false;
    }

    _startAutoAdvance();
    return false;
  }

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
    // Safety net in case ProcessingState.completed doesn't fire
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

  void _startAutoAdvance() {
    if (_autoAdvancing) return;
    _autoAdvancing = true;

    // Slight delay to allow UI to settle and prevent race conditions
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

  Future<void> playSong(Song song,
      {List<Song>? playlist,
      bool forceReload = false,
      bool userInitiated = true}) async {
    final account = _account;
    if (_currentSong != null &&
        _songKey(_currentSong!) == _songKey(song) &&
        _error == PlayerError.none &&
        !forceReload) {
      _adoptPlaylist(song, playlist);
      if (userInitiated) _markUserInteraction();
      unawaited(_prefetchBackgroundQueue(_playRequestId, account: account));
      
      // If the player is currently playing, or buffering/loading, just ensure
      // the intent to play is captured, but don't reset the whole fetch process!
      if (!_isPlaying && _player.processingState != ProcessingState.idle) {
        _startPlayback();
      }
      return;
    }

    final requestId = ++_playRequestId;
    try {
      await _player.stop(); // Stop audio engine synchronously to prevent overlapping
    } catch (_) {}

    
    _completionHandledForKey = null;
    _currentSong = song;
    _hasPlayedSomeAudio = false;
    _error = PlayerError.none;
    _isLoading = true;
    _position = Duration.zero;
    _duration =
        song.duration > 0 ? Duration(seconds: song.duration) : Duration.zero;
    _adoptPlaylist(song, playlist);
    if (userInitiated) _markUserInteraction();
    notifyListeners();
    
    try {
      _isLiked = await storage.isLiked(song.id);
      notifyListeners();

      final playedSong =
          await _playFirstWorkingCandidate(song, requestId, account: account)
              .timeout(const Duration(seconds: 35), onTimeout: () => null);
      if (requestId != _playRequestId) return;
      if (playedSong == null) {
        _error = PlayerError.streamUnavailable;
        _isLoading = false;
        notifyListeners();
        return;
      }
      _currentSong = playedSong;
      _isLiked = await storage.isLiked(playedSong.id);
      await _recordRecentlyPlayed(playedSong);
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

  Future<void> _recoverFromPlaybackError({bool force = false}) async {
    if (_recoveringPlaybackError) return;
    final now = DateTime.now();
    if (!force &&
        now.difference(_lastPlaybackRecoveryAt) < const Duration(seconds: 5)) {
      return;
    }
    _lastPlaybackRecoveryAt = now;
    _recoveringPlaybackError = true;
    try {
      final song = _currentSong;
      if (song == null) return;
      debugPrint('Recovering playback for ${song.title} (force=$force)');
      ApiService.clearStreamCache(song.id, song.source);
      _isLoading = true;
      _error = PlayerError.none;
      notifyListeners();
      await playSong(song,
          playlist: _queue, forceReload: true, userInitiated: false);
    } catch (e) {
      _error = PlayerError.networkError;
      _isLoading = false;
      notifyListeners();
    } finally {
      _recoveringPlaybackError = false;
    }
  }

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

  Future<Song?> _playFirstWorkingCandidate(Song song, int requestId,
      {AccountProvider? account}) async {
    final tried = <String>{};
    final completer = Completer<Song?>();
    var finished = false;
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

    Future<bool> tryCandidate(Song candidate,
        {bool strict = false, bool fastTimeout = false}) async {
      if (finished || requestId != _playRequestId) return false;
      final key = '${candidate.source}:${candidate.id}';
      if (tried.contains(key) || candidate.id.isEmpty) return false;
      tried.add(key);
      if (strict && !isSimilar(candidate)) return false;
      try {
        final localPath = await _validDownloadPath(candidate);
        if (localPath != null) {
          if (finished || requestId != _playRequestId) return false;
          await _setAudioSourceAndPlay(
              candidate, _localAudioSourceFor(candidate, localPath), requestId,
              prefetchQueue: false, account: account);
          return true;
        }
        final urls =
            await ApiService.getStreamUrls(candidate.id, candidate.source)
                .timeout(fastTimeout
                    ? const Duration(seconds: 8)
                    : const Duration(seconds: 15));
        if (urls.isEmpty) return false;
        for (final url in urls) {
          if (finished || requestId != _playRequestId) return false;
          try {
            final source =
                await _audioSourceFor(candidate, url, account: account);
            await _setAudioSourceAndPlay(candidate, source, requestId,
                prefetchQueue: true, account: account);
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

    final success = await tryCandidate(song);
    if (success && requestId == _playRequestId) {
      finished = true;
      completer.complete(song);
      return completer.future;
    }
    if (requestId != _playRequestId) return null;
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

  String _normalizeForComparison(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');

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
    unawaited(_prefetchBackgroundQueue(_playRequestId, account: _account));
  }

  Future<void> _setAudioSourceAndPlay(
      Song song, AudioSource audioSource, int requestId,
      {required bool prefetchQueue, AccountProvider? account}) async {
    if (requestId != _playRequestId) return;
    
    _sourceSongs
      ..clear()
      ..add(song);
    _sourceKeys
      ..clear()
      ..add(_songKey(song));
    _lastAudioSourceIndex = 0;
    
    if (requestId != _playRequestId) return;
    
    await _player
        .setAudioSource(audioSource)
        .timeout(prefetchQueue ? _streamLoadTimeout : _localLoadTimeout);
        
    if (requestId != _playRequestId) return;
    
    await _applyTempo();
    await _syncAndroidAudioEffects(forceRecreate: true);
    if (prefetchQueue) {
      unawaited(_prefetchBackgroundQueue(requestId, account: account));
    }
    if (requestId == _playRequestId) _startPlayback();
    _scheduleAndroidEffectResync();
  }

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

  Future<void> _prefetchBackgroundQueue(int requestId,
      {AccountProvider? account}) async {
    if (requestId != _playRequestId) return;
    final start = _queueIndex + 1;
    if (start >= _queue.length) return;
    // Pre-fetch the next 3 songs immediately with small staggered delays
    // so they are READY to play instantly when the user taps next.
    // Then warm the rest of the queue more lazily.
    for (var i = start; i < math.min(_queue.length, start + 3); i++) {
      if (requestId != _playRequestId) return;
      final song = _queue[i];
      if (await _validDownloadPath(song) != null) continue;
      try {
        unawaited(ApiService.getStreamUrls(song.id, song.source));
      } catch (_) {}
      // Small delay between rapid-fire fetches to avoid rate limiting.
      await Future.delayed(const Duration(milliseconds: 400));
    }
    // Then warm the remaining queue lazily (slower, after playback is stable).
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

  String _songKey(Song song) => '${song.source}:${song.id}';

  Future<String?> _validDownloadPath(Song song) async {
    final key = _songKey(song);
    var path = _downloadPaths[key] ?? await storage.getDownloadPath(song);
    if (path == null || path.isEmpty) return null;
    if (await File(path).exists()) {
      _downloadPaths[key] = path;
      return path;
    }
    _downloadPaths.remove(key);
    await storage.removeDownloadedSong(song);
    notifyListeners();
    return null;
  }

  double get _effectivePitch => _pitchEnabled ? _pitch : _speed;
  Future<void> _applyTempo() async {
    await _player.setSpeed(_speed);
    await _player.setPitch(_effectivePitch);
  }

  Future<Map<String, String>?> _headersFor(Song song,
      {AccountProvider? account}) async {
    final baseHeaders = ApiService.streamHeaders(song.source, song.id) ?? {};
    if (song.source == 'youtube') {
      return baseHeaders.isEmpty ? null : baseHeaders;
    }
    if (account != null && account.isSignedIn) {
      final authHeaders = await account.getAuthHeaders();
      if (authHeaders != null) return {...baseHeaders, ...authHeaders};
    }
    return baseHeaders.isEmpty ? null : baseHeaders;
  }

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

  Future<void> pauseFromNotification() async {
    _markUserInteraction();
    _isPlaying = false;
    notifyListeners();
    unawaited(_syncAndroidAudioEffects(playingOverride: false));
    unawaited(_player.pause());
  }

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
    if (defaultTargetPlatform == TargetPlatform.android) {
      unawaited(_effectsChannel.invokeMethod<void>('releaseAudioEffects'));
    }
  }

  Future<void> playNext({bool userInitiated = true}) async {
    if (userInitiated) {
      _markUserInteraction();
    }
    if (_queue.isEmpty) {
      return;
    }
    if (_queue.length == 1) {
      if (userInitiated) {
        await _playQueueIndex(0, userInitiated: userInitiated);
      } else {
        await _stopPlaybackAtQueueBoundary();
      }
      return;
    }
    final attempted = <int>{};
    var nextIndex = _nextQueueIndex(excluded: attempted);
    while (nextIndex != null && attempted.length < _queue.length) {
      attempted.add(nextIndex);
      final played =
          await _playQueueIndex(nextIndex, userInitiated: userInitiated);
      if (played || userInitiated) {
        return;
      }
      nextIndex = _nextQueueIndex(excluded: attempted);
    }
    await _stopPlaybackAtQueueBoundary();
  }

  int? _nextQueueIndex({Set<int> excluded = const {}}) {
    if (_queue.isEmpty || _queue.length == 1) return null;
    final current = _queueIndex.clamp(0, _queue.length - 1).toInt();
    if (_shuffleOn) {
      final remaining = <int>[
        for (var i = 0; i < _queue.length; i++)
          if (i != current && !excluded.contains(i)) i
      ];
      if (remaining.isEmpty) return null;
      return remaining[
          DateTime.now().millisecondsSinceEpoch % remaining.length];
    }
    for (var offset = 1; offset <= _queue.length; offset++) {
      final next = (current + offset) % _queue.length;
      if (!excluded.contains(next)) return next;
    }
    return null;
  }

  Future<void> _stopPlaybackAtQueueBoundary() async {
    _playRequestId++;
    _completionHandledForKey = null;
    await _player.pause();
    _isPlaying = false;
    _isLoading = false;
    _error = PlayerError.none;
    notifyListeners();
  }

  Future<void> playPrevious({bool userInitiated = true}) async {
    if (userInitiated) _markUserInteraction();
    if (_queue.isEmpty) return;
    if (_queueIndex <= 0) {
      await seek(Duration.zero);
      return;
    }
    await _playQueueIndex(_queueIndex - 1, userInitiated: userInitiated);
  }

  Future<bool> _playQueueIndex(int index, {required bool userInitiated}) async {
    if (_queue.isEmpty) return false;
    final clamped = index.clamp(0, _queue.length - 1).toInt();
    _queueIndex = clamped;
    await playSong(_queue[clamped],
        playlist: _queue, forceReload: true, userInitiated: userInitiated);
    return _currentSong != null && _error == PlayerError.none;
  }

  Future<void> _recordRecentlyPlayed(Song song) async {
    await storage.addRecentlyPlayed(song);
    _recentRevision++;
    notifyListeners();
    final account = _account;
    if (account != null && account.isSignedIn && song.source == 'youtube') {
      final headers = await account.getAuthHeaders();
      if (headers != null) {
        unawaited(YoutubeAccountService().rateSong(headers, song.id, 'none'));
      }
    }
  }

  Future<void> removeFromRecentlyPlayed(Song song) async {
    await storage.removeRecentlyPlayed(song);
    _recentRevision++;
    notifyListeners();
  }

  Future<void> seek(Duration position, {bool userInitiated = true}) async {
    if (userInitiated) _markUserInteraction();
    final clamped = _clampToDuration(position);
    _position = clamped;
    _seekLoadingSuppressedUntil =
        DateTime.now().add(const Duration(milliseconds: 900));
    notifyListeners();
    await _player.seek(clamped);
  }

  Duration _clampToDuration(Duration value) {
    if (value.isNegative) return Duration.zero;
    if (_duration > Duration.zero && value > _duration) return _duration;
    return value;
  }

  Future<void> setSpeed(double value) async {
    _markUserInteraction();
    _speed = value.clamp(0.5, 2.0).toDouble();
    if (!_pitchEnabled) _pitch = _speed;
    await _applyTempo();
    notifyListeners();
  }

  Future<void> setPitch(double value) async {
    _markUserInteraction();
    _pitch = value.clamp(0.5, 2.0).toDouble();
    if (_pitchEnabled) await _applyTempo();
    notifyListeners();
  }

  Future<void> setPitchEnabled(bool enabled) async {
    _markUserInteraction();
    _pitchEnabled = enabled;
    if (!enabled) _pitch = _speed;
    await _applyTempo();
    notifyListeners();
  }

  void _startPlayback() {
    _isPlaying = true;
    unawaited(_syncAndroidAudioEffects(playingOverride: true));
    unawaited(_player.play().catchError((Object error, StackTrace stackTrace) {
      debugPrint('Playback start failed: $error');
      unawaited(_recoverFromPlaybackError());
    }));
  }

  void _scheduleAndroidEffectResync() {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    Future<void>.delayed(const Duration(milliseconds: 250), () async {
      if (_currentSong != null) await _syncAndroidAudioEffects();
    });
    Future<void>.delayed(const Duration(milliseconds: 900), () async {
      if (_currentSong != null) await _syncAndroidAudioEffects();
    });
  }

  Future<void> beginScratch() async {
    _markUserInteraction();
    _seekLoadingSuppressedUntil =
        DateTime.now().add(const Duration(milliseconds: 1400));
    _lastScratchSpeedSyncAt = DateTime.fromMillisecondsSinceEpoch(0);
  }

  Future<void> scratchTo(Duration position, double deltaRadians) async {
    final clamped = _clampToDuration(position);
    _position = clamped;
    _seekLoadingSuppressedUntil =
        DateTime.now().add(const Duration(milliseconds: 1400));
    notifyListeners();
    final now = DateTime.now();
    if (_isPlaying &&
        now.difference(_lastScratchSpeedSyncAt) >
            const Duration(milliseconds: 90)) {
      _lastScratchSpeedSyncAt = now;
      final intensity = (deltaRadians.abs() * 7).clamp(0.0, 1.0).toDouble();
      final shuttleSpeed = deltaRadians >= 0
          ? (0.9 + intensity * 1.1).clamp(0.5, 2.0).toDouble()
          : (0.5 + intensity * 0.8).clamp(0.5, 2.0).toDouble();
      await _player.setSpeed(shuttleSpeed);
      await _player.setPitch(_pitchEnabled ? _pitch : shuttleSpeed);
    }
    await _player.seek(clamped);
  }

  Future<void> endScratch(Duration position) async {
    await seek(position, userInitiated: false);
    await _applyTempo();
    if (_isPlaying) _startPlayback();
  }

  Future<void> setBass(double value) async {
    _markUserInteraction();
    _bass = value.clamp(0.0, 1.0).toDouble();
    await _syncAndroidAudioEffects();
    notifyListeners();
  }

  Future<void> setReverb(double value) async {
    _markUserInteraction();
    _reverb = value.clamp(0.0, 1.0).toDouble();
    await _syncAndroidAudioEffects();
    notifyListeners();
  }

  Future<bool> downloadSong(Song song) async {
    final key = _songKey(song);
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
        if (progress >= 1 ||
            now.difference(lastProgressNotify) >
                const Duration(milliseconds: 140)) {
          lastProgressNotify = now;
          notifyListeners();
        }
      });
      _downloadPaths[key] = localPath;
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

  Future<String?> downloadToDevice(Song song,
      {bool applyEffects = false}) async {
    final key = _songKey(song);
    if (_exportingKeys.contains(key)) {
      return null;
    }
    _exportingKeys.add(key);
    notifyListeners();
    try {
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
      if (applyEffects) {
        final nameParts = fileName.split('.');
        if (nameParts.length > 1) {
          final ext = nameParts.removeLast();
          fileName = '${nameParts.join('.')}_applied.$ext';
        } else {
          fileName = '${fileName}_applied';
        }
      }
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

  Future<void> removeDownload(Song song) async {
    final key = _songKey(song);
    _downloadPaths.remove(key);
    _downloadProgress.remove(key);
    _downloadingKeys.remove(key);
    await storage.removeDownloadedSong(song);
    notifyListeners();
  }

  Future<void> _syncAndroidAudioEffects(
      {bool forceRecreate = false, bool? playingOverride}) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    final sessionId = _player.androidAudioSessionId;
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

  void registerUserInteraction() {
    _markUserInteraction();
  }

  void _markUserInteraction() {
    _completionHandledForKey = null;
  }

  void toggleShuffle() {
    _markUserInteraction();
    _shuffleOn = !_shuffleOn;
    notifyListeners();
  }

  void toggleRepeat() {
    _markUserInteraction();
    _repeatOne = !_repeatOne;
    unawaited(_player.setLoopMode(_repeatOne ? LoopMode.one : LoopMode.off));
    notifyListeners();
  }

  Future<void> toggleLike({AccountProvider? account}) async {
    _markUserInteraction();
    final song = _currentSong;
    if (song == null) return;
    final actualAccount = account ?? _account;
    final newState = !await storage.isLiked(song.id);
    await storage.toggleLike(song);
    _isLiked = newState;
    _recentRevision++;
    notifyListeners();
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

  @override
  void notifyListeners() {
    _publishAudioServiceState();
    super.notifyListeners();
  }

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

  @override
  void dispose() {
    if (defaultTargetPlatform == TargetPlatform.android) {
      unawaited(_effectsChannel.invokeMethod<void>('releaseAudioEffects'));
    }
    _player.dispose();
    super.dispose();
  }

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

  String _deviceFileName(Song song, String localPath) {
    final dot = localPath.lastIndexOf('.');
    final extension = dot >= 0 ? localPath.substring(dot) : '.m4a';
    final raw = '${song.title} - ${song.artist}';
    final name = raw
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final capped = name.length > 90 ? name.substring(0, 90).trim() : name;
    return '${capped.isEmpty ? song.id : capped}$extension';
  }

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
