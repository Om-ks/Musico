package com.example.flutter_application_1

import android.content.Intent
import android.content.ContentValues
import android.util.Log
import android.media.audiofx.BassBoost
import android.media.audiofx.EnvironmentalReverb
import android.media.audiofx.Equalizer
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.antonkarpenko.ffmpegkit.FFmpegKit
import com.antonkarpenko.ffmpegkit.ReturnCode
import java.io.File
import java.io.FileInputStream
import java.util.Locale

class MainActivity : AudioServiceActivity() {
    private var bassBoost: BassBoost? = null
    private var equalizer: Equalizer? = null
    private var environmentalReverb: EnvironmentalReverb? = null
    private var activeSessionId: Int = 0
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "musico/audio_effects"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setAudioEffects" -> {
                    val sessionId = call.argument<Int>("sessionId") ?: 0
                    val bass = call.argument<Double>("bass") ?: 0.0
                    val reverb = call.argument<Double>("reverb") ?: 0.0
                    val forceRecreate = call.argument<Boolean>("forceRecreate") ?: false
                    val playing = call.argument<Boolean>("playing") ?: true
                    result.success(applyEffects(sessionId, bass, reverb, forceRecreate, playing))
                }
                "releaseAudioEffects" -> {
                    releaseEffects()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "musico/device_files"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveToDownloads" -> {
                    val sourcePath = call.argument<String>("sourcePath") ?: ""
                    val displayName = call.argument<String>("displayName") ?: "musico_audio.m4a"
                    val mimeType = call.argument<String>("mimeType") ?: "audio/*"
                    val applyEffects = call.argument<Boolean>("applyEffects") ?: false
                    val bass = call.argument<Double>("bass") ?: 0.0
                    val reverb = call.argument<Double>("reverb") ?: 0.0
                    val speed = call.argument<Double>("speed") ?: 1.0
                    val pitch = call.argument<Double>("pitch") ?: 1.0
                    Thread {
                        runCatching {
                            saveToDownloads(sourcePath, displayName, mimeType, applyEffects, bass, reverb, speed, pitch)
                        }.onSuccess { saved ->
                            mainHandler.post { result.success(saved) }
                        }.onFailure { error ->
                            mainHandler.post { result.error("SAVE_FAILED", error.message, null) }
                        }
                    }.start()
                }
                "shareText" -> {
                    val text = call.argument<String>("text") ?: ""
                    runCatching {
                        shareText(text)
                    }.onSuccess {
                        result.success(true)
                    }.onFailure { error ->
                        result.error("SHARE_FAILED", error.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun applyEffects(sessionId: Int, bass: Double, reverb: Double, forceRecreate: Boolean = false, playing: Boolean = true): Map<String, Any> {
        if (sessionId <= 0) return mapOf("success" to false)

        val normalizedBass = bass.coerceIn(0.0, 1.0)
        val normalizedReverb = reverb.coerceIn(0.0, 1.0)

        if (normalizedBass > 0.001 || normalizedReverb > 0.001) {
            disableJustAudioOffloadForSession(sessionId)
        }

        if (forceRecreate || sessionId != activeSessionId) {
            releaseEffects()
            activeSessionId = sessionId
        }

        // Always apply the actual slider reverb value directly. This prevents race conditions 
        // during pause/resume transitions where the values could be set out of order.
        val softwareApplied = setJustAudioSoftwareEffects(
            sessionId,
            normalizedBass.toFloat(),
            normalizedReverb.toFloat()
        )

        return mapOf(
            "bass" to (softwareApplied && normalizedBass > 0.001),
            "reverb" to (softwareApplied && normalizedReverb > 0.001),
            "software" to softwareApplied,
            "sessionId" to sessionId
        )
    }

    private fun resetEqualizerBands(eq: Equalizer) {
        for (band in 0 until eq.numberOfBands.toInt()) {
            eq.setBandLevel(band.toShort(), 0)
        }
    }

    private fun bassGainDb(bass: Double): Double {
        return Math.pow(bass.coerceIn(0.0, 1.0), 1.18) * 10.5
    }

    private fun bassBoostStrength(bass: Double): Int {
        return Math.round(Math.pow(bass.coerceIn(0.0, 1.0), 1.35) * 720.0)
            .toInt()
            .coerceIn(0, 720)
    }

    private fun bassBandWeight(centerHz: Double): Double {
        return when {
            centerHz <= 90.0 -> 1.0
            centerHz <= 160.0 -> 0.78
            centerHz <= 280.0 -> 0.46
            centerHz <= 420.0 -> 0.18
            else -> 0.0
        }
    }

    private fun configureEnvironmentalReverb(effect: EnvironmentalReverb, amount: Double) {
        val wet = Math.pow(amount.coerceIn(0.0, 1.0), 1.12)
        effect.setRoomLevel(lerpShort(-5200, -2100, wet))
        effect.setRoomHFLevel(lerpShort(-5000, -1800, wet))
        effect.setDecayTime(lerpInt(850, 4600, wet))
        effect.setDecayHFRatio(lerpShort(520, 840, wet))
        effect.setReflectionsLevel(lerpShort(-6500, -2800, wet))
        effect.setReflectionsDelay(lerpInt(12, 60, wet))
        effect.setReverbLevel(lerpShort(-5400, -650, wet))
        effect.setReverbDelay(lerpInt(36, 115, wet))
        effect.setDiffusion(lerpShort(560, 1000, wet))
        effect.setDensity(lerpShort(640, 1000, wet))
    }

    private fun reverbSendLevel(reverb: Double): Float {
        val wet = Math.pow(reverb.coerceIn(0.0, 1.0), 1.18)
        return (0.06 + wet * 0.94).coerceIn(0.0, 1.0).toFloat()
    }

    private fun lerpInt(start: Int, end: Int, amount: Double): Int {
        return Math.round(start + (end - start) * amount).toInt()
    }

    private fun lerpShort(start: Int, end: Int, amount: Double): Short {
        return lerpInt(start, end, amount).coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort()
    }

    private fun setJustAudioAuxEffect(sessionId: Int, effectId: Int, sendLevel: Float): Boolean {
        return runCatching {
            val cls = Class.forName("com.ryanheise.just_audio.AudioPlayer")
            val m = cls.getMethod("setAuxEffectForSession", Int::class.javaPrimitiveType, Int::class.javaPrimitiveType, Float::class.javaPrimitiveType)
            m.invoke(null, sessionId, effectId, sendLevel) as? Boolean ?: false
        }.getOrElse { false }
    }

    private fun clearJustAudioAuxEffect(sessionId: Int): Boolean {
        return runCatching {
            val cls = Class.forName("com.ryanheise.just_audio.AudioPlayer")
            val m = cls.getMethod("clearAuxEffectForSession", Int::class.javaPrimitiveType)
            m.invoke(null, sessionId) as? Boolean ?: false
        }.getOrDefault(false)
    }

    private fun setJustAudioSoftwareEffects(sessionId: Int, bass: Float, reverb: Float): Boolean {
        return runCatching {
            val cls = Class.forName("com.ryanheise.just_audio.AudioPlayer")
            val m = cls.getMethod("setSoftwareEffectsForSession", Int::class.javaPrimitiveType, Float::class.javaPrimitiveType, Float::class.javaPrimitiveType)
            m.invoke(null, sessionId, bass, reverb) as? Boolean ?: false
        }.getOrDefault(false)
    }

    private fun disableJustAudioOffloadForSession(sessionId: Int): Boolean {
        return runCatching {
            val cls = Class.forName("com.ryanheise.just_audio.AudioPlayer")
            val m = cls.getMethod("disableAudioOffloadForSession", Int::class.javaPrimitiveType)
            m.invoke(null, sessionId) as? Boolean ?: false
        }.getOrDefault(false)
    }

    private fun saveToDownloads(sourcePath: String, displayName: String, mimeType: String, applyEffects: Boolean = false, bass: Double = 0.0, reverb: Double = 0.0, speed: Double = 1.0, pitch: Double = 1.0): String {
        val source = File(sourcePath)
        require(source.exists()) { "Source file does not exist" }

        val fileToSave: File = if (applyEffects) {
            val output = File(cacheDir, "proc_${System.currentTimeMillis()}.m4a")
            
            val filters = mutableListOf<String>()
            val normalizedBass = bass.coerceIn(0.0, 1.0)
            val normalizedReverb = reverb.coerceIn(0.0, 1.0)
            if (normalizedBass > 0.01) {
                val gain = bassGainDb(normalizedBass)
                filters.add("bass=f=75:w=0.55:g=${ff(gain)}")
                filters.add("equalizer=f=150:width_type=h:w=110:g=${ff(gain * 0.58)}")
                filters.add("equalizer=f=280:width_type=h:w=180:g=${ff(gain * 0.24)}")
            }
            if (normalizedReverb > 0.01) {
                filters.add(
                    "aecho=0.72:0.78:55|115|190|265:" +
                        "${ff(normalizedReverb * 0.36)}|" +
                        "${ff(normalizedReverb * 0.28)}|" +
                        "${ff(normalizedReverb * 0.22)}|" +
                        ff(normalizedReverb * 0.16)
                )
            }
            filters.add("asetrate=44100*${ff(pitch.coerceIn(0.5, 2.0))}")
            filters.addAll(atempoFilters(speed / pitch))
            filters.add("aresample=44100")
            filters.add("alimiter=limit=0.96")
            val f = filters.joinToString(",")
            
            val cmd = "-i \"${source.absolutePath}\" -af \"$f\" -c:a aac -b:a 256k \"${output.absolutePath}\" -y"
            val session = FFmpegKit.execute(cmd)
            if (ReturnCode.isSuccess(session.returnCode)) {
                output
            } else {
                throw IllegalStateException("FFmpeg effects export failed: ${session.returnCode}")
            }
        } else source

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = applicationContext.contentResolver
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
                put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                put(MediaStore.MediaColumns.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/Musico")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: error("Insert failed")
            resolver.openOutputStream(uri)?.use { out -> FileInputStream(fileToSave).use { inp -> inp.copyTo(out) } }
            values.clear(); values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            return uri.toString()
        }
        val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "Musico")
        if (!dir.exists()) dir.mkdirs()
        val target = File(dir, displayName)
        fileToSave.copyTo(target, overwrite = true)
        return target.absolutePath
    }

    private fun shareText(text: String) {
        val intent = Intent(Intent.ACTION_SEND).apply { type = "text/plain"; putExtra(Intent.EXTRA_TEXT, text) }
        startActivity(Intent.createChooser(intent, "Share song"))
    }

    private fun atempoFilters(value: Double): List<String> {
        val filters = mutableListOf<String>()
        var tempo = value.coerceIn(0.25, 4.0)
        while (tempo < 0.5) {
            filters.add("atempo=0.5")
            tempo /= 0.5
        }
        while (tempo > 2.0) {
            filters.add("atempo=2.0")
            tempo /= 2.0
        }
        filters.add("atempo=${ff(tempo)}")
        return filters
    }

    private fun ff(value: Double): String {
        return String.format(Locale.US, "%.4f", value)
    }

    private fun releaseEffects() {
        if (activeSessionId > 0) {
            runCatching { clearJustAudioAuxEffect(activeSessionId) }
        }
        runCatching { bassBoost?.release() }; runCatching { environmentalReverb?.release() }; runCatching { equalizer?.release() }
        bassBoost = null; environmentalReverb = null; equalizer = null; activeSessionId = 0
    }
}
