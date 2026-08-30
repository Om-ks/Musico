package com.ryanheise.just_audio;

import androidx.media3.common.C;
import androidx.media3.common.audio.AudioProcessor.AudioFormat;
import androidx.media3.common.audio.AudioProcessor.UnhandledAudioFormatException;
import androidx.media3.common.audio.BaseAudioProcessor;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Arrays;

final class MusicoEffectsAudioProcessor extends BaseAudioProcessor {
    private static final float TWO_PI = (float)(Math.PI * 2.0);

    private volatile float bassAmount = 0f;
    private volatile float reverbAmount = 0f;
    private int sampleRate;
    private int channelCount;
    private float[] lowState = new float[0];
    private float[][] delayLines = new float[0][];
    private float[] lastDelayed = new float[0];
    private int delayPosition;

    void setLevels(float bass, float reverb) {
        bassAmount  = clamp01(bass);
        reverbAmount = clamp01(reverb);
    }

    @Override
    protected AudioFormat onConfigure(AudioFormat inputAudioFormat)
            throws UnhandledAudioFormatException {
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT) {
            return AudioFormat.NOT_SET;
        }
        sampleRate   = inputAudioFormat.sampleRate;
        channelCount = Math.max(1, inputAudioFormat.channelCount);
        ensureState();
        return inputAudioFormat;
    }

    @Override
    public boolean isActive() {
        return inputAudioFormat.encoding == C.ENCODING_PCM_16BIT;
    }

    @Override
    public void queueInput(ByteBuffer inputBuffer) {
        final int remaining = inputBuffer.remaining();
        if (remaining <= 0) return;

        final ByteBuffer outputBuffer = replaceOutputBuffer(remaining);
        outputBuffer.order(ByteOrder.LITTLE_ENDIAN);

        // Safety: if not properly configured, pass through unchanged
        if (sampleRate <= 0 || channelCount <= 0) {
            // Copy bytes directly
            final int pos = inputBuffer.position();
            outputBuffer.put(inputBuffer);
            outputBuffer.flip();
            return;
        }

        final float bass   = bassAmount;
        final float reverb = reverbAmount;

        // Fast bypass – no effects active
        if (bass <= 0.001f && reverb <= 0.001f) {
            final int pos = inputBuffer.position();
            outputBuffer.put(inputBuffer);
            outputBuffer.flip();
            return;
        }

        final int delayLength = Math.max(1, (int)(sampleRate * 0.25f));

        if (lowState.length < channelCount
                || delayLines.length < channelCount
                || delayLines.length == 0
                || delayLines[0] == null
                || delayLines[0].length != delayLength
                || lastDelayed.length < channelCount) {
            ensureState();
        }

        // Bass: low-pass cutoff ~120 Hz
        final float bassAlpha = 1.0f - (float)Math.exp(-TWO_PI * 120.0f / sampleRate);
        // Exponential gain so the slider feels smooth across full range:
        //   10% → ~0.25,  50% → ~1.35,  100% → ~3.06
        final float bassGain  = (float)(Math.exp(1.4 * bass) - 1.0);

        // Reverb parameters - boosted so it's clearly audible
        final float wetGain  = reverb * 1.40f;
        final float dryGain  = 1.0f - reverb * 0.25f;
        final float feedback = 0.35f + reverb * 0.35f;

        final int[] leftTaps  = {
            (int)(sampleRate * 0.033f), (int)(sampleRate * 0.067f),
            (int)(sampleRate * 0.123f), (int)(sampleRate * 0.197f)
        };
        final int[] rightTaps = {
            (int)(sampleRate * 0.041f), (int)(sampleRate * 0.079f),
            (int)(sampleRate * 0.141f), (int)(sampleRate * 0.211f)
        };
        final float[] tapGains = { 0.40f, 0.28f, 0.19f, 0.13f };

        inputBuffer.order(ByteOrder.LITTLE_ENDIAN);
        int sampleIndex = 0;

        while (inputBuffer.remaining() >= 2) {
            int ch = sampleIndex % channelCount;

            if (ch >= channelCount || ch >= lowState.length
                    || ch >= delayLines.length || ch >= lastDelayed.length) {
                outputBuffer.putShort(inputBuffer.getShort());
                sampleIndex++;
                continue;
            }

            float dry = inputBuffer.getShort() / 32768.0f;
            float out = dry;

            // Bass boost
            if (bass > 0.001f) {
                float low = lowState[ch] + bassAlpha * (dry - lowState[ch]);
                lowState[ch] = low;
                out = softClip(dry + low * bassGain);
            }

            // Reverb
            final float[] line = delayLines[ch];
            if (reverb > 0.001f && line != null && line.length == delayLength) {
                final int[] taps = (ch == 0) ? leftTaps : rightTaps;
                float delayed = 0.0f;
                for (int i = 0; i < taps.length; i++) {
                    int tap = taps[i];
                    if (tap <= 0 || tap >= delayLength) continue;
                    int readIdx = delayPosition - tap;
                    if (readIdx < 0) readIdx += delayLength;
                    if (readIdx >= 0 && readIdx < delayLength) {
                        delayed += line[readIdx] * tapGains[i];
                    }
                }
                float crossFeed = delayed;
                if (channelCount == 2) {
                    int opp = 1 - ch;
                    if (opp >= 0 && opp < lastDelayed.length) {
                        crossFeed = delayed * 0.78f + lastDelayed[opp] * 0.22f;
                    }
                }
                lastDelayed[ch] = delayed;
                if (delayPosition >= 0 && delayPosition < delayLength) {
                    line[delayPosition] = softClip(dry + crossFeed * feedback);
                }
                out = softClip(out * dryGain + crossFeed * wetGain);
            }

            outputBuffer.putShort(floatToPcm16(out));
            sampleIndex++;

            if (channelCount > 0 && sampleIndex % channelCount == 0) {
                delayPosition = (delayPosition + 1) % delayLength;
            }
        }

        // Copy any leftover bytes
        while (inputBuffer.hasRemaining()) {
            outputBuffer.put(inputBuffer.get());
        }
        outputBuffer.flip();
    }

    @Override
    protected void onFlush() {
        // Only clear the bass IIR filter state to avoid DC-offset click on seek.
        // Intentionally keep reverb delay lines alive across pause/resume/seek.
        if (lowState != null && lowState.length == channelCount) {
            Arrays.fill(lowState, 0.0f);
        }
    }

    @Override
    protected void onReset() {
        sampleRate    = 0;
        channelCount  = 0;
        lowState      = new float[0];
        delayLines    = new float[0][];
        lastDelayed   = new float[0];
        delayPosition = 0;
    }

    private void ensureState() {
        lowState   = new float[channelCount];
        int delayLength = Math.max(1, (int)(sampleRate * 0.25f));
        delayLines  = new float[channelCount][delayLength];
        lastDelayed = new float[channelCount];
        delayPosition = 0;
    }

    private static float clamp01(float v) {
        return v < 0f ? 0f : (v > 1f ? 1f : v);
    }

    private static float softClip(float v) {
        if (v >  1.5f) return  0.985f;
        if (v < -1.5f) return -0.985f;
        return (float)Math.tanh(v);
    }

    private static short floatToPcm16(float v) {
        float clamped = v < -1f ? -1f : (v > 1f ? 1f : v);
        return (short)Math.round(clamped * 32767.0f);
    }
}
