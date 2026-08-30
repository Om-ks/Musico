package com.ryanheise.just_audio;

import android.content.Context;
import android.media.audiofx.AudioEffect;
import android.media.audiofx.Equalizer;
import android.media.audiofx.LoudnessEnhancer;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import androidx.media3.common.AuxEffectInfo;
import androidx.media3.common.C;
import androidx.media3.common.audio.AudioProcessor;
import androidx.media3.exoplayer.DefaultLivePlaybackSpeedControl;
import androidx.media3.exoplayer.DefaultLoadControl;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.ExoPlaybackException;
import androidx.media3.exoplayer.LivePlaybackSpeedControl;
import androidx.media3.exoplayer.LoadControl;
import androidx.media3.common.MediaItem;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.PlaybackParameters;
import androidx.media3.common.Player;
import androidx.media3.common.Player.PositionInfo;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.common.Timeline;
import androidx.media3.common.Tracks;
import androidx.media3.common.TrackSelectionParameters;
import androidx.media3.common.TrackSelectionParameters.AudioOffloadPreferences;
import androidx.media3.common.AudioAttributes;
import androidx.media3.extractor.DefaultExtractorsFactory;
import androidx.media3.common.Metadata;
import androidx.media3.exoplayer.metadata.MetadataOutput;
import androidx.media3.extractor.metadata.icy.IcyHeaders;
import androidx.media3.extractor.metadata.icy.IcyInfo;
import androidx.media3.exoplayer.source.ClippingMediaSource; // Deprecated
import androidx.media3.exoplayer.source.MediaSource; // Deprecated
import androidx.media3.exoplayer.source.ProgressiveMediaSource; // Deprecated
import androidx.media3.exoplayer.source.ShuffleOrder;
import androidx.media3.exoplayer.source.ShuffleOrder.DefaultShuffleOrder;
import androidx.media3.exoplayer.source.SilenceMediaSource; // Deprecated
import androidx.media3.common.TrackGroup;
import androidx.media3.exoplayer.dash.DashMediaSource; // Deprecated
import androidx.media3.exoplayer.hls.HlsMediaSource; // Deprecated
import androidx.media3.exoplayer.audio.AudioSink;
import androidx.media3.exoplayer.audio.DefaultAudioSink;
import androidx.media3.exoplayer.trackselection.TrackSelectionArray;
import androidx.media3.datasource.DataSource;
import androidx.media3.datasource.DefaultDataSource;
import androidx.media3.datasource.DefaultHttpDataSource;
import androidx.media3.common.MimeTypes;
import androidx.media3.common.util.Util;
import io.flutter.Log;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.EventChannel.EventSink;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.Iterator;
import java.util.List;
import java.util.Map;
import java.util.Random;

public class AudioPlayer implements MethodCallHandler, Player.Listener, MetadataOutput {

    static final String TAG = "AudioPlayer";

    private static Random random = new Random();
    private static final Map<Integer, ExoPlayer> sessionPlayers = new HashMap<Integer, ExoPlayer>();
    private static final Map<Integer, MusicoEffectsAudioProcessor> sessionEffects = new HashMap<Integer, MusicoEffectsAudioProcessor>();

    private final Context context;
    private final MethodChannel methodChannel;
    private final BetterEventChannel eventChannel;
    private final BetterEventChannel dataEventChannel;

    private ProcessingState processingState;
    private long updatePosition;
    private long updateTime;
    private long bufferedPosition;
    private Long seekPos;
    private long initialPos;
    private Integer initialIndex;
    private Result prepareResult;
    private Result playResult;
    private Result seekResult;
    private Map<String, MediaSource> mediaSources = new HashMap<String, MediaSource>();
    private IcyInfo icyInfo;
    private IcyHeaders icyHeaders;
    private int errorCount;
    private AudioAttributes pendingAudioAttributes;
    private LoadControl loadControl;
    private boolean offloadSchedulingEnabled;
    private LivePlaybackSpeedControl livePlaybackSpeedControl;
    private List<Object> rawAudioEffects;
    private List<AudioEffect> audioEffects = new ArrayList<AudioEffect>();
    private Map<String, AudioEffect> audioEffectsMap = new HashMap<String, AudioEffect>();
    private int lastPlaylistLength = 0;
    private Map<String, Object> pendingPlaybackEvent;

    private ExoPlayer player;
    private final MusicoEffectsAudioProcessor musicoEffectsProcessor = new MusicoEffectsAudioProcessor();
    private Integer audioSessionId;
    private MediaSource mediaSource;
    private Integer currentIndex;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable bufferWatcher = new Runnable() {
        @Override
        public void run() {
            if (player == null) {
                return;
            }

            long newBufferedPosition = player.getBufferedPosition();
            if (newBufferedPosition != bufferedPosition) {
                broadcastImmediatePlaybackEvent();
            }
            switch (player.getPlaybackState()) {
            case Player.STATE_BUFFERING:
                handler.postDelayed(this, 200);
                break;
            case Player.STATE_READY:
                if (player.getPlayWhenReady()) {
                    handler.postDelayed(this, 500);
                } else {
                    handler.postDelayed(this, 1000);
                }
                break;
            default:
            }
        }
    };

    public AudioPlayer(
        final Context applicationContext,
        final BinaryMessenger messenger,
        final String id,
        Map<?, ?> audioLoadConfiguration,
        List<Object> rawAudioEffects,
        Boolean offloadSchedulingEnabled
    ) {
        this.context = applicationContext;
        this.rawAudioEffects = rawAudioEffects;
        this.offloadSchedulingEnabled = offloadSchedulingEnabled != null ? offloadSchedulingEnabled : false;
        methodChannel = new MethodChannel(messenger, "com.ryanheise.just_audio.methods." + id);
        methodChannel.setMethodCallHandler(this);
        eventChannel = new BetterEventChannel(messenger, "com.ryanheise.just_audio.events." + id);
        dataEventChannel = new BetterEventChannel(messenger, "com.ryanheise.just_audio.data." + id);
        processingState = ProcessingState.none;
        if (audioLoadConfiguration != null) {
            Map<?, ?> loadControlMap = (Map<?, ?>)audioLoadConfiguration.get("androidLoadControl");
            if (loadControlMap != null) {
                DefaultLoadControl.Builder builder = new DefaultLoadControl.Builder()
                    .setBufferDurationsMs(
                        (int)((getLong(loadControlMap.get("minBufferDuration")))/1000),
                        (int)((getLong(loadControlMap.get("maxBufferDuration")))/1000),
                        (int)((getLong(loadControlMap.get("bufferForPlaybackDuration")))/1000),
                        (int)((getLong(loadControlMap.get("bufferForPlaybackAfterRebufferDuration")))/1000)
                    )
                    .setPrioritizeTimeOverSizeThresholds((Boolean)loadControlMap.get("prioritizeTimeOverSizeThresholds"))
                    .setBackBuffer((int)((getLong(loadControlMap.get("backBufferDuration")))/1000), false);
                if (loadControlMap.get("targetBufferBytes") != null) {
                    builder.setTargetBufferBytes((Integer)loadControlMap.get("targetBufferBytes"));
                }
                loadControl = builder.build();
            }
            Map<?, ?> livePlaybackSpeedControlMap = (Map<?, ?>)audioLoadConfiguration.get("androidLivePlaybackSpeedControl");
            if (livePlaybackSpeedControlMap != null) {
                DefaultLivePlaybackSpeedControl.Builder builder = new DefaultLivePlaybackSpeedControl.Builder()
                    .setFallbackMinPlaybackSpeed((float)((double)((Double)livePlaybackSpeedControlMap.get("fallbackMinPlaybackSpeed"))))
                    .setFallbackMaxPlaybackSpeed((float)((double)((Double)livePlaybackSpeedControlMap.get("fallbackMaxPlaybackSpeed"))))
                    .setMinUpdateIntervalMs(((getLong(livePlaybackSpeedControlMap.get("minUpdateInterval")))/1000))
                    .setProportionalControlFactor((float)((double)((Double)livePlaybackSpeedControlMap.get("proportionalControlFactor"))))
                    .setMaxLiveOffsetErrorMsForUnitSpeed(((getLong(livePlaybackSpeedControlMap.get("maxLiveOffsetErrorForUnitSpeed")))/1000))
                    .setTargetLiveOffsetIncrementOnRebufferMs(((getLong(livePlaybackSpeedControlMap.get("targetLiveOffsetIncrementOnRebuffer")))/1000))
                    .setMinPossibleLiveOffsetSmoothingFactor((float)((double)((Double)livePlaybackSpeedControlMap.get("minPossibleLiveOffsetSmoothingFactor"))));
                livePlaybackSpeedControl = builder.build();
            }
        }
    }

    private void startWatchingBuffer() {
        handler.removeCallbacks(bufferWatcher);
        handler.post(bufferWatcher);
    }

    private void setAudioSessionId(int audioSessionId) {
        if (this.audioSessionId != null) {
            sessionPlayers.remove(this.audioSessionId);
            sessionEffects.remove(this.audioSessionId);
        }
        if (audioSessionId == C.AUDIO_SESSION_ID_UNSET) {
            this.audioSessionId = null;
        } else {
            this.audioSessionId = audioSessionId;
            if (player != null) {
                sessionPlayers.put(audioSessionId, player);
                sessionEffects.put(audioSessionId, musicoEffectsProcessor);
            }
        }
        clearAudioEffects();
        if (this.audioSessionId != null) {
            for (Object rawAudioEffect : rawAudioEffects) {
                Map<?, ?> json = (Map<?, ?>)rawAudioEffect;
                AudioEffect audioEffect = decodeAudioEffect(rawAudioEffect, this.audioSessionId);
                if ((Boolean)json.get("enabled")) {
                    audioEffect.setEnabled(true);
                }
                audioEffects.add(audioEffect);
                audioEffectsMap.put((String)json.get("type"), audioEffect);
            }
        }
        enqueuePlaybackEvent();
    }

    @Override
    public void onAudioSessionIdChanged(int audioSessionId) {
        setAudioSessionId(audioSessionId);
        broadcastPendingPlaybackEvent();
    }

    public static boolean setAuxEffectForSession(int audioSessionId, int effectId, float sendLevel) {
        ExoPlayer player = sessionPlayers.get(audioSessionId);
        if (player == null) return false;
        disableAudioOffload(player);
        player.setAuxEffectInfo(new AuxEffectInfo(effectId, sendLevel));
        return true;
    }

    public static boolean disableAudioOffloadForSession(int audioSessionId) {
        ExoPlayer player = sessionPlayers.get(audioSessionId);
        if (player == null) return false;
        disableAudioOffload(player);
        return true;
    }

    public static boolean setSoftwareEffectsForSession(int audioSessionId, float bass, float reverb) {
        ExoPlayer player = sessionPlayers.get(audioSessionId);
        MusicoEffectsAudioProcessor processor = sessionEffects.get(audioSessionId);
        if (player == null || processor == null) return false;
        disableAudioOffload(player);
        processor.setLevels(bass, reverb);
        return true;
    }

    private static void disableAudioOffload(ExoPlayer player) {
        player.setTrackSelectionParameters(
            player.getTrackSelectionParameters()
                .buildUpon()
                .setAudioOffloadPreferences(
                    new AudioOffloadPreferences.Builder()
                        .setAudioOffloadMode(AudioOffloadPreferences.AUDIO_OFFLOAD_MODE_DISABLED)
                        .build()
                )
                .build()
        );
    }

    public static boolean clearAuxEffectForSession(int audioSessionId) {
        ExoPlayer player = sessionPlayers.get(audioSessionId);
        if (player == null) return false;
        player.clearAuxEffectInfo();
        return true;
    }

    @Override
    public void onMetadata(Metadata metadata) {
        for (int i = 0; i < metadata.length(); i++) {
            final Metadata.Entry entry = metadata.get(i);
            if (entry instanceof IcyInfo) {
                icyInfo = (IcyInfo) entry;
                broadcastImmediatePlaybackEvent();
            }
        }
    }

    @Override
    public void onTracksChanged(Tracks tracks) {
        for (int i = 0; i < tracks.getGroups().size(); i++) {
            TrackGroup trackGroup = tracks.getGroups().get(i).getMediaTrackGroup();

            for (int j = 0; j < trackGroup.length; j++) {
                Metadata metadata = trackGroup.getFormat(j).metadata;

                if (metadata != null) {
                    for (int k = 0; k < metadata.length(); k++) {
                        final Metadata.Entry entry = metadata.get(k);
                        if (entry instanceof IcyHeaders) {
                            icyHeaders = (IcyHeaders) entry;
                            broadcastImmediatePlaybackEvent();
                        }
                    }
                }
            }
        }
    }

    private boolean updatePositionIfChanged() {
        if (getCurrentPosition() == updatePosition) return false;
        updatePosition = getCurrentPosition();
        updateTime = System.currentTimeMillis();
        return true;
    }

    private void updatePosition() {
        updatePosition = getCurrentPosition();
        updateTime = System.currentTimeMillis();
    }

    @Override
    public void onPositionDiscontinuity(PositionInfo oldPosition, PositionInfo newPosition, int reason) {
        updatePosition();
        switch (reason) {
        case Player.DISCONTINUITY_REASON_AUTO_TRANSITION:
        case Player.DISCONTINUITY_REASON_SEEK:
            updateCurrentIndex();
            break;
        }
        broadcastImmediatePlaybackEvent();
    }

    @Override
    public void onTimelineChanged(Timeline timeline, int reason) {
        if (initialPos != C.TIME_UNSET || initialIndex != null) {
            int windowIndex = initialIndex != null ? initialIndex : 0;
            player.seekTo(windowIndex, initialPos);
            initialIndex = null;
            initialPos = C.TIME_UNSET;
        }
        if (updateCurrentIndex()) {
            broadcastImmediatePlaybackEvent();
        }
        if (player.getPlaybackState() == Player.STATE_ENDED) {
            try {
                if (player.getPlayWhenReady()) {
                    if (lastPlaylistLength == 0 && player.getMediaItemCount() > 0) {
                        player.seekTo(0, 0L);
                    } else if (player.hasNextMediaItem()) {
                        player.seekToNextMediaItem();
                    }
                } else {
                    if (player.getCurrentMediaItemIndex() < player.getMediaItemCount()) {
                        player.seekTo(player.getCurrentMediaItemIndex(), 0L);
                    }
                }
            } catch (Exception e) {
                e.printStackTrace();
            }
        }
        lastPlaylistLength = player.getMediaItemCount();
    }

    private boolean updateCurrentIndex() {
        Integer newIndex = player.getCurrentMediaItemIndex();
        if (!newIndex.equals(currentIndex)) {
            currentIndex = newIndex;
            return true;
        }
        return false;
    }

    @Override
    public void onPlaybackStateChanged(int playbackState) {
        switch (playbackState) {
        case Player.STATE_READY:
            if (player.getPlayWhenReady())
                updatePosition();
            processingState = ProcessingState.ready;
            broadcastImmediatePlaybackEvent();
            if (prepareResult != null) {
                Map<String, Object> response = new HashMap<>();
                response.put("duration", getDuration() == C.TIME_UNSET ? null : (1000 * getDuration()));
                prepareResult.success(response);
                prepareResult = null;
                if (pendingAudioAttributes != null) {
                    player.setAudioAttributes(pendingAudioAttributes, false);
                    pendingAudioAttributes = null;
                }
            }
            if (seekResult != null) {
                completeSeek();
            }
            break;
        case Player.STATE_BUFFERING:
            updatePositionIfChanged();
            if (processingState != ProcessingState.buffering && processingState != ProcessingState.loading) {
                processingState = ProcessingState.buffering;
                broadcastImmediatePlaybackEvent();
            }
            startWatchingBuffer();
            break;
        case Player.STATE_ENDED:
            if (processingState != ProcessingState.completed) {
                updatePosition();
                processingState = ProcessingState.completed;
                broadcastImmediatePlaybackEvent();
            }
            if (prepareResult != null) {
                Map<String, Object> response = new HashMap<>();
                prepareResult.success(response);
                prepareResult = null;
                if (pendingAudioAttributes != null) {
                    player.setAudioAttributes(pendingAudioAttributes, false);
                    pendingAudioAttributes = null;
                }
            }
            if (playResult != null) {
                playResult.success(new HashMap<String, Object>());
                playResult = null;
            }
            break;
        }
    }

    @Override
    public void onPlayerError(PlaybackException error) {
        if (error instanceof ExoPlaybackException) {
            final ExoPlaybackException exoError = (ExoPlaybackException)error;
            sendError(String.valueOf(exoError.type), exoError.getMessage(), mapOf("index", currentIndex));
        } else {
            sendError(String.valueOf(error.errorCode), error.getMessage(), mapOf("index", currentIndex));
        }
        errorCount++;
        if (player.hasNextMediaItem() && currentIndex != null && errorCount <= 5) {
            int nextIndex = currentIndex + 1;
            Timeline timeline = player.getCurrentTimeline();
            if (nextIndex < timeline.getWindowCount()) {
                player.setMediaSource(mediaSource);
                player.prepare();
                player.seekTo(nextIndex, 0);
            }
        }
    }

    private void completeSeek() {
        seekPos = null;
        seekResult.success(new HashMap<String, Object>());
        seekResult = null;
    }

    @Override
    public void onMethodCall(final MethodCall call, final Result result) {
        ensurePlayerInitialized();

        try {
            switch (call.method) {
            case "load":
                Long initialPosition = getLong(call.argument("initialPosition"));
                Integer initialIndex = call.argument("initialIndex");
                load(getAudioSource(call.argument("audioSource")),
                        initialPosition == null ? C.TIME_UNSET : initialPosition / 1000,
                        initialIndex, result);
                break;
            case "play":
                play(result);
                break;
            case "pause":
                pause();
                result.success(new HashMap<String, Object>());
                break;
            case "setVolume":
                setVolume((float) ((double) ((Double) call.argument("volume"))));
                result.success(new HashMap<String, Object>());
                break;
            case "setSpeed":
                setSpeed((float) ((double) ((Double) call.argument("speed"))));
                result.success(new HashMap<String, Object>());
                break;
            case "setPitch":
                setPitch((float) ((double) ((Double) call.argument("pitch"))));
                result.success(new HashMap<String, Object>());
                break;
            case "setSkipSilence":
                setSkipSilenceEnabled((Boolean) call.argument("enabled"));
                result.success(new HashMap<String, Object>());
                break;
            case "setLoopMode":
                setLoopMode((Integer) call.argument("loopMode"));
                result.success(new HashMap<String, Object>());
                break;
            case "setShuffleMode":
                setShuffleModeEnabled((Integer) call.argument("shuffleMode") == 1);
                result.success(new HashMap<String, Object>());
                break;
            case "setShuffleOrder":
                setShuffleOrder(call.argument("audioSource"));
                result.success(new HashMap<String, Object>());
                break;
            case "setAutomaticallyWaitsToMinimizeStalling":
                result.success(new HashMap<String, Object>());
                break;
            case "setCanUseNetworkResourcesForLiveStreamingWhilePaused":
                result.success(new HashMap<String, Object>());
                break;
            case "setPreferredPeakBitRate":
                result.success(new HashMap<String, Object>());
                break;
            case "seek":
                Long position = getLong(call.argument("position"));
                Integer index = call.argument("index");
                seek(position == null ? C.TIME_UNSET : position / 1000, index, result);
                break;
            case "concatenatingInsertAll":
                concatenating(call.argument("id"))
                        .addMediaSources(call.argument("index"), getAudioSources(call.argument("children")), handler, () -> result.success(new HashMap<String, Object>()));
                break;
            case "concatenatingRemoveRange":
                concatenating(call.argument("id"))
                        .removeMediaSourceRange(call.argument("startIndex"), call.argument("endIndex"), handler, () -> result.success(new HashMap<String, Object>()));
                break;
            case "concatenatingMove":
                concatenating(call.argument("id"))
                        .moveMediaSource(call.argument("currentIndex"), call.argument("newIndex"), handler, () -> result.success(new HashMap<String, Object>()));
                break;
            case "setAndroidAudioAttributes":
                setAudioAttributes(call.argument("contentType"), call.argument("flags"), call.argument("usage"));
                result.success(new HashMap<String, Object>());
                break;
            case "audioEffectSetEnabled":
                audioEffectSetEnabled(call.argument("type"), call.argument("enabled"));
                result.success(new HashMap<String, Object>());
                break;
            case "androidLoudnessEnhancerSetTargetGain":
                loudnessEnhancerSetTargetGain(call.argument("targetGain"));
                result.success(new HashMap<String, Object>());
                break;
            case "androidEqualizerGetParameters":
                result.success(equalizerAudioEffectGetParameters());
                break;
            case "androidEqualizerBandSetGain":
                equalizerBandSetGain(call.argument("bandIndex"), call.argument("gain"));
                result.success(new HashMap<String, Object>());
                break;
            default:
                result.notImplemented();
                break;
            }
        } catch (IllegalStateException e) {
            e.printStackTrace();
            result.error("Illegal state: " + e.getMessage(), e.toString(), null);
        } catch (Exception e) {
            e.printStackTrace();
            result.error("Error: " + e, e.toString(), null);
        } finally {
            broadcastPendingPlaybackEvent();
        }
    }

    private ShuffleOrder decodeShuffleOrder(List<Integer> indexList) {
        int[] shuffleIndices = new int[indexList.size()];
        for (int i = 0; i < shuffleIndices.length; i++) {
            shuffleIndices[i] = indexList.get(i);
        }
        return new DefaultShuffleOrder(shuffleIndices, random.nextLong());
    }

    @SuppressWarnings("deprecation")
    private androidx.media3.exoplayer.source.ConcatenatingMediaSource concatenating(final Object index) {
        return (androidx.media3.exoplayer.source.ConcatenatingMediaSource)mediaSources.get((String)index);
    }

    private void setShuffleOrder(final Object json) {
        Map<?, ?> map = (Map<?, ?>)json;
        String id = (String)map.get("id");
        MediaSource mediaSource = mediaSources.get(id);
        if (mediaSource == null) return;
        if (mediaSource instanceof androidx.media3.exoplayer.source.ConcatenatingMediaSource) {
            ((androidx.media3.exoplayer.source.ConcatenatingMediaSource)mediaSource).setShuffleOrder(decodeShuffleOrder((List<Integer>)map.get("shuffleOrder")));
        }
    }

    private MediaSource getAudioSource(final Object json) {
        Map<?, ?> map = (Map<?, ?>)json;
        String id = (String)map.get("id");
        MediaSource mediaSource = mediaSources.get(id);
        if (mediaSource == null) {
            mediaSource = decodeAudioSource(map);
            mediaSources.put(id, mediaSource);
        }
        return mediaSource;
    }

    private DefaultExtractorsFactory buildExtractorsFactory(Map<?, ?> options) {
        DefaultExtractorsFactory extractorsFactory = new DefaultExtractorsFactory();
        extractorsFactory.setConstantBitrateSeekingEnabled(true);
        return extractorsFactory;
    }

    @SuppressWarnings("deprecation")
    private MediaSource decodeAudioSource(final Object json) {
        Map<?, ?> map = (Map<?, ?>)json;
        String id = (String)map.get("id");
        switch ((String)map.get("type")) {
        case "progressive":
            return new ProgressiveMediaSource.Factory(buildDataSourceFactory((Map<?, ?>)map.get("headers")), buildExtractorsFactory((Map<?, ?>)map.get("options")))
                    .createMediaSource(new MediaItem.Builder()
                            .setUri(Uri.parse((String)map.get("uri")))
                            .setTag(id)
                            .build());
        case "dash":
            return new DashMediaSource.Factory(buildDataSourceFactory((Map<?, ?>)map.get("headers")))
                    .createMediaSource(new MediaItem.Builder()
                            .setUri(Uri.parse((String)map.get("uri")))
                            .setMimeType(MimeTypes.APPLICATION_MPD)
                            .setTag(id)
                            .build());
        case "hls":
            return new HlsMediaSource.Factory(buildDataSourceFactory((Map<?, ?>)map.get("headers")))
                    .createMediaSource(new MediaItem.Builder()
                            .setUri(Uri.parse((String)map.get("uri")))
                            .setMimeType(MimeTypes.APPLICATION_M3U8)
                            .build());
        case "silence":
            return new SilenceMediaSource.Factory()
                    .setDurationUs(getLong(map.get("duration")))
                    .setTag(id)
                    .createMediaSource();
        case "concatenating":
            return new androidx.media3.exoplayer.source.ConcatenatingMediaSource(
                    false, // isAtomic
                    (Boolean)map.get("useLazyPreparation"),
                    decodeShuffleOrder((List<Integer>)map.get("shuffleOrder")),
                    getAudioSourcesArray(map.get("children")));
        case "clipping":
            Long start = getLong(map.get("start"));
            Long end = getLong(map.get("end"));
            return new ClippingMediaSource(getAudioSource(map.get("child")),
                    start != null ? start : 0,
                    end != null ? end : C.TIME_END_OF_SOURCE);
        case "looping":
            int count = (Integer)map.get("count");
            MediaSource looperChild = getAudioSource(map.get("child"));
            MediaSource[] looperChildren = new MediaSource[count];
            for (int i = 0; i < looperChildren.length; i++) {
                looperChildren[i] = looperChild;
            }
            return new androidx.media3.exoplayer.source.ConcatenatingMediaSource(looperChildren);
        default:
            throw new IllegalArgumentException("Unknown AudioSource type: " + map.get("type"));
        }
    }

    private MediaSource[] getAudioSourcesArray(final Object json) {
        List<MediaSource> mediaSources = getAudioSources(json);
        MediaSource[] mediaSourcesArray = new MediaSource[mediaSources.size()];
        mediaSources.toArray(mediaSourcesArray);
        return mediaSourcesArray;
    }

    private List<MediaSource> getAudioSources(final Object json) {
        List<?> audioSources = (List<?>)json;
        List<MediaSource> mediaSources = new ArrayList<MediaSource>();
        for (int i = 0 ; i < audioSources.size(); i++) {
            mediaSources.add(getAudioSource(audioSources.get(i)));
        }
        return mediaSources;
    }

    private AudioEffect decodeAudioEffect(final Object json, int audioSessionId) {
        Map<?, ?> map = (Map<?, ?>)json;
        String type = (String)map.get("type");
        switch (type) {
        case "AndroidLoudnessEnhancer":
            int targetGain = (int)Math.round((((Double)map.get("targetGain")) * 1000.0));
            LoudnessEnhancer loudnessEnhancer = new LoudnessEnhancer(audioSessionId);
            loudnessEnhancer.setTargetGain(targetGain);
            return loudnessEnhancer;
        case "AndroidEqualizer":
            return new Equalizer(0, audioSessionId);
        default:
            throw new IllegalArgumentException("Unknown AudioEffect type: " + type);
        }
    }

    private void clearAudioEffects() {
        for (Iterator<AudioEffect> it = audioEffects.iterator(); it.hasNext();) {
            it.next().release();
            it.remove();
        }
        audioEffectsMap.clear();
    }

    private DataSource.Factory buildDataSourceFactory(Map<?, ?> headers) {
        final Map<String, String> stringHeaders = castToStringMap(headers);
        String userAgent = null;
        if (stringHeaders != null) {
            userAgent = stringHeaders.remove("User-Agent");
            if (userAgent == null) userAgent = stringHeaders.remove("user-agent");
        }
        if (userAgent == null) userAgent = Util.getUserAgent(context, "just_audio");
        DefaultHttpDataSource.Factory httpDataSourceFactory = new DefaultHttpDataSource.Factory()
            .setUserAgent(userAgent)
            .setAllowCrossProtocolRedirects(true);
        if (stringHeaders != null && stringHeaders.size() > 0) {
            httpDataSourceFactory.setDefaultRequestProperties(stringHeaders);
        }
        return new DefaultDataSource.Factory(context, httpDataSourceFactory);
    }

    private void load(final MediaSource mediaSource, final long initialPosition, final Integer initialIndex, final Result result) {
        this.initialPos = initialPosition;
        this.initialIndex = initialIndex;
        currentIndex = initialIndex != null ? initialIndex : 0;
        if (player != null) player.stop();
        errorCount = 0;
        prepareResult = result;
        updatePosition();
        processingState = ProcessingState.loading;
        enqueuePlaybackEvent();
        this.mediaSource = mediaSource;
        player.setMediaSource(mediaSource);
        player.prepare();
    }

    private void ensurePlayerInitialized() {
        if (player == null) {
            DefaultRenderersFactory renderersFactory = new DefaultRenderersFactory(context) {
                @Override
                protected AudioSink buildAudioSink(
                        Context context,
                        boolean enableFloatOutput,
                        boolean enableAudioTrackPlaybackParams) {
                    return new DefaultAudioSink.Builder(context)
                            .setAudioProcessors(new AudioProcessor[] { musicoEffectsProcessor })
                            .setEnableFloatOutput(enableFloatOutput)
                            .setEnableAudioTrackPlaybackParams(enableAudioTrackPlaybackParams)
                            .build();
                }
            };
            ExoPlayer.Builder builder = new ExoPlayer.Builder(context, renderersFactory);
            if (loadControl != null) builder.setLoadControl(loadControl);
            if (livePlaybackSpeedControl != null) builder.setLivePlaybackSpeedControl(livePlaybackSpeedControl);
            player = builder.build();
            setAudioSessionId(player.getAudioSessionId());
            player.addListener(this);
        }
    }

    private void setAudioAttributes(int contentType, int flags, int usage) {
        AudioAttributes audioAttributes = new AudioAttributes.Builder()
            .setContentType(contentType)
            .setFlags(flags)
            .setUsage(usage)
            .build();
        if (processingState == ProcessingState.loading) {
            pendingAudioAttributes = audioAttributes;
        } else {
            player.setAudioAttributes(audioAttributes, false);
        }
    }

    private void audioEffectSetEnabled(String type, boolean enabled) {
        audioEffectsMap.get(type).setEnabled(enabled);
    }

    private void loudnessEnhancerSetTargetGain(double targetGain) {
        int targetGainMillibels = (int)Math.round(targetGain * 1000.0);
        ((LoudnessEnhancer)audioEffectsMap.get("AndroidLoudnessEnhancer")).setTargetGain(targetGainMillibels);
    }

    private Map<String, Object> equalizerAudioEffectGetParameters() {
        Equalizer equalizer = (Equalizer)audioEffectsMap.get("AndroidEqualizer");
        ArrayList<Object> rawBands = new ArrayList<>();
        for (short i = 0; i < equalizer.getNumberOfBands(); i++) {
            rawBands.add(mapOf(
                "index", (int)i,
                "lowerFrequency", (double)equalizer.getBandFreqRange(i)[0] / 1000.0,
                "upperFrequency", (double)equalizer.getBandFreqRange(i)[1] / 1000.0,
                "centerFrequency", (double)equalizer.getCenterFreq(i) / 1000.0,
                "gain", equalizer.getBandLevel(i) / 1000.0
            ));
        }
        return mapOf(
            "parameters", mapOf(
                "minDecibels", equalizer.getBandLevelRange()[0] / 1000.0,
                "maxDecibels", equalizer.getBandLevelRange()[1] / 1000.0,
                "bands", rawBands
            )
        );
    }

    private void equalizerBandSetGain(int bandIndex, double gain) {
        ((Equalizer)audioEffectsMap.get("AndroidEqualizer")).setBandLevel((short)bandIndex, (short)(Math.round(gain * 1000.0)));
    }

    private Map<String, Object> createPlaybackEvent() {
        final Map<String, Object> event = new HashMap<String, Object>();
        Long duration = getDuration() == C.TIME_UNSET ? null : (1000 * getDuration());
        bufferedPosition = player != null ? player.getBufferedPosition() : 0L;
        event.put("processingState", processingState.ordinal());
        event.put("updatePosition", 1000 * updatePosition);
        event.put("updateTime", updateTime);
        event.put("bufferedPosition", 1000 * Math.max(updatePosition, bufferedPosition));
        event.put("icyMetadata", collectIcyMetadata());
        event.put("duration", duration);
        event.put("currentIndex", currentIndex);
        event.put("androidAudioSessionId", audioSessionId);
        return event;
    }

    private void broadcastPendingPlaybackEvent() {
        if (pendingPlaybackEvent != null) {
            eventChannel.success(pendingPlaybackEvent);
            pendingPlaybackEvent = null;
        }
    }

    private void enqueuePlaybackEvent() {
        pendingPlaybackEvent = createPlaybackEvent();
    }

    private void broadcastImmediatePlaybackEvent() {
        enqueuePlaybackEvent();
        broadcastPendingPlaybackEvent();
    }

    private Map<String, Object> collectIcyMetadata() {
        final Map<String, Object> icyData = new HashMap<>();
        if (icyInfo != null) {
            final Map<String, String> info = new HashMap<>();
            info.put("title", icyInfo.title);
            info.put("url", icyInfo.url);
            icyData.put("info", info);
        }
        if (icyHeaders != null) {
            final Map<String, Object> headers = new HashMap<>();
            headers.put("bitrate", icyHeaders.bitrate);
            headers.put("genre", icyHeaders.genre);
            headers.put("name", icyHeaders.name);
            headers.put("metadataInterval", icyHeaders.metadataInterval);
            headers.put("url", icyHeaders.url);
            headers.put("isPublic", icyHeaders.isPublic);
            icyData.put("headers", headers);
        }
        return icyData;
    }

    private long getCurrentPosition() {
        if (initialPos != C.TIME_UNSET) return initialPos;
        if (processingState == ProcessingState.none || processingState == ProcessingState.loading) return Math.max(0, player.getCurrentPosition());
        return seekPos != null && seekPos != C.TIME_UNSET ? seekPos : player.getCurrentPosition();
    }

    private long getDuration() {
        return (processingState == ProcessingState.none || processingState == ProcessingState.loading || player == null) ? C.TIME_UNSET : player.getDuration();
    }

    private void sendError(String errorCode, String errorMsg, Object details) {
        if (prepareResult != null) {
            prepareResult.error(errorCode, errorMsg, details);
            prepareResult = null;
        }
        eventChannel.error(errorCode, errorMsg, details);
    }

    public void play(Result result) {
        if (player.getPlayWhenReady()) {
            result.success(new HashMap<String, Object>());
            return;
        }
        if (playResult != null) playResult.success(new HashMap<String, Object>());
        playResult = result;
        player.setPlayWhenReady(true);
        updatePosition();
        if (processingState == ProcessingState.completed && playResult != null) {
            playResult.success(new HashMap<String, Object>());
            playResult = null;
        }
    }

    public void pause() {
        if (!player.getPlayWhenReady()) return;
        player.setPlayWhenReady(false);
        updatePosition();
        if (playResult != null) {
            playResult.success(new HashMap<String, Object>());
            playResult = null;
        }
    }

    public void setVolume(final float volume) { player.setVolume(volume); }
    public void setSpeed(final float speed) {
        PlaybackParameters params = player.getPlaybackParameters();
        if (params.speed == speed) return;
        player.setPlaybackParameters(new PlaybackParameters(speed, params.pitch));
        if (player.getPlayWhenReady()) updatePosition();
        enqueuePlaybackEvent();
    }
    public void setPitch(final float pitch) {
        PlaybackParameters params = player.getPlaybackParameters();
        if (params.pitch == pitch) return;
        player.setPlaybackParameters(new PlaybackParameters(params.speed, pitch));
        enqueuePlaybackEvent();
    }
    public void setSkipSilenceEnabled(final boolean enabled) { player.setSkipSilenceEnabled(enabled); }
    public void setLoopMode(final int mode) { player.setRepeatMode(mode); }
    public void setShuffleModeEnabled(final boolean enabled) { player.setShuffleModeEnabled(enabled); }

    public void seek(final long position, final Integer index, final Result result) {
        if (processingState == ProcessingState.none || processingState == ProcessingState.loading) {
            result.success(new HashMap<String, Object>());
            return;
        }
        abortSeek();
        seekPos = position;
        seekResult = result;
        int windowIndex = index != null ? index : player.getCurrentMediaItemIndex();
        player.seekTo(windowIndex, position);
    }

    public void dispose() {
        if (processingState == ProcessingState.loading) abortExistingConnection();
        if (playResult != null) {
            playResult.success(new HashMap<String, Object>());
            playResult = null;
        }
        mediaSources.clear();
        mediaSource = null;
        clearAudioEffects();
        if (player != null) {
            if (audioSessionId != null) {
                sessionPlayers.remove(audioSessionId);
                sessionEffects.remove(audioSessionId);
            }
            player.release();
            player = null;
            processingState = ProcessingState.none;
            broadcastImmediatePlaybackEvent();
        }
        eventChannel.endOfStream();
        dataEventChannel.endOfStream();
    }

    private void abortSeek() {
        if (seekResult != null) {
            try { seekResult.success(new HashMap<String, Object>()); } catch (RuntimeException e) {}
            seekResult = null;
            seekPos = null;
        }
    }

    private void abortExistingConnection() { sendError("abort", "Connection aborted", null); }

    public static Long getLong(Object o) { return (o == null || o instanceof Long) ? (Long)o : Long.valueOf(((Integer)o).intValue()); }

    static <T> T mapGet(Object o, String key) { return (o instanceof Map) ? (T) ((Map<?, ?>)o).get(key) : null; }

    static Map<String, Object> mapOf(Object... args) {
        Map<String, Object> map = new HashMap<>();
        for (int i = 0; i < args.length; i += 2) map.put((String)args[i], args[i + 1]);
        return map;
    }

    static Map<String, String> castToStringMap(Map<?, ?> map) {
        if (map == null) return null;
        Map<String, String> map2 = new HashMap<>();
        for (Object key : map.keySet()) map2.put((String)key, (String)map.get(key));
        return map2;
    }

    enum ProcessingState { none, loading, buffering, ready, completed }
}
