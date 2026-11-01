//
//  MixerRender.c
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Each sample: the level glides toward the one set (about 25 ms, so a drag or
//  a mute doesn't click); above 100 % a limiter that reacts at once and lets go
//  over about 80 ms keeps the peaks under -1 dBFS, and a soft knee (as in
//  FineTune, GPL-3.0) catches what is left. At or under 100 % the sound only
//  gets the level.
//

#include "MixerRender.h"

#include <math.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>

#pragma clang diagnostic warning "-Wfunction-effects"

struct MixerVoice {
    _Atomic float target;
    _Atomic uint64_t cycles;
    _Atomic uint64_t silentCycles;
    _Atomic float inputPeak;
    _Atomic float outputPeak;
    /// The render thread's own.
    float gain;
    float limit;
    float glide;
    float release;
};

static const float ceiling = 0.891f;   // -1 dBFS
static const float knee = 0.95f;

MixerVoice *mixer_voice_create(double sampleRate, float gain) {
    MixerVoice *voice = calloc(1, sizeof(MixerVoice));
    if (!voice) return NULL;
    double rate = sampleRate > 0 ? sampleRate : 48000;
    atomic_init(&voice->target, gain);
    atomic_init(&voice->cycles, 0);
    atomic_init(&voice->silentCycles, 0);
    atomic_init(&voice->inputPeak, 0);
    atomic_init(&voice->outputPeak, 0);
    voice->gain = gain;
    voice->limit = 1;
    voice->glide = (float)(1 - exp(-1 / (rate * 0.025)));
    voice->release = (float)(1 - exp(-1 / (rate * 0.080)));
    return voice;
}

void mixer_voice_destroy(MixerVoice *voice) { free(voice); }

void mixer_voice_set_gain(MixerVoice *voice, float gain) {
    atomic_store_explicit(&voice->target, gain, memory_order_relaxed);
}

uint64_t mixer_voice_cycles(const MixerVoice *voice) {
    return atomic_load_explicit(&((MixerVoice *)voice)->cycles, memory_order_relaxed);
}

uint64_t mixer_voice_silent_cycles(const MixerVoice *voice) {
    return atomic_load_explicit(&((MixerVoice *)voice)->silentCycles, memory_order_relaxed);
}

void mixer_voice_take_peaks(MixerVoice *voice, float *input, float *output) {
    *input = atomic_exchange_explicit(&voice->inputPeak, 0, memory_order_relaxed);
    *output = atomic_exchange_explicit(&voice->outputPeak, 0, memory_order_relaxed);
}

static inline float magnitude(float x) CA_REALTIME_API { return x < 0 ? -x : x; }

static inline float soften(float x) CA_REALTIME_API {
    float size = magnitude(x);
    if (size <= knee) return x;
    float over = size - knee;
    float bent = knee + (1 - knee) * (over / (over + (1 - knee)));
    return x < 0 ? -bent : bent;
}

/// Which tap channel feeds an output channel: the same one, or a mono tap's only one to the
/// first two; -1 for none (an output wider than the tap stays silent there).
static inline int sourceChannel(UInt32 channel, UInt32 inputs) CA_REALTIME_API {
    if (channel < inputs) return (int)channel;
    if (inputs == 1 && channel < 2) return 0;
    return -1;
}

OSStatus mixer_render(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
                      const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime,
                      void *_Nullable context) CA_REALTIME_API {
    (void)device; (void)now; (void)inputTime; (void)outputTime;
    MixerVoice *voice = context;
    const float target = atomic_load_explicit(&voice->target, memory_order_relaxed);
    const UInt32 inputCount = input ? input->mNumberBuffers : 0;
    const UInt32 outputCount = output ? output->mNumberBuffers : 0;
    // Every output stream starts from the same state; the first one rendered carries it on.
    float endGain = voice->gain, endLimit = voice->limit;
    bool carried = false, heard = false;
    float loudestIn = 0, loudestOut = 0;

    for (UInt32 o = 0; o < outputCount; o++) {
        AudioBuffer *out = &output->mBuffers[o];
        if (!out->mData || out->mNumberChannels == 0) continue;
        float *dst = out->mData;
        const UInt32 outChannels = out->mNumberChannels;
        const UInt32 outFrames = out->mDataByteSize / (UInt32)(sizeof(float) * outChannels);
        // The tap's stream comes after any input of the device's own (a headset's microphone).
        const UInt32 i = inputCount > outputCount ? inputCount - outputCount + o : o;
        const AudioBuffer *in = i < inputCount ? &input->mBuffers[i] : NULL;
        if (!in || !in->mData || in->mNumberChannels == 0) {
            for (UInt32 n = 0; n < outFrames * outChannels; n++) dst[n] = 0;
            continue;
        }
        const float *src = in->mData;
        const UInt32 inChannels = in->mNumberChannels;
        const UInt32 inFrames = in->mDataByteSize / (UInt32)(sizeof(float) * inChannels);
        const UInt32 frames = inFrames < outFrames ? inFrames : outFrames;

        float gain = voice->gain, limit = voice->limit;
        for (UInt32 f = 0; f < frames; f++) {
            gain += (target - gain) * voice->glide;
            const float *frame = src + f * inChannels;
            float peak = 0;
            for (UInt32 c = 0; c < inChannels; c++) {
                float size = magnitude(frame[c]);
                if (size > peak) peak = size;
            }
            if (peak > 0) heard = true;
            if (peak > loudestIn) loudestIn = peak;
            // Linked across channels, so a boost doesn't shift the stereo image.
            if (gain > 1 || limit < 1) {
                float loud = peak * gain;
                if (loud * limit > ceiling) limit = ceiling / loud;
                else limit += (1 - limit) * voice->release;
                if (limit > 1) limit = 1;
            }
            const float level = gain * limit;
            float *to = dst + f * outChannels;
            for (UInt32 c = 0; c < outChannels; c++) {
                int from = sourceChannel(c, inChannels);
                to[c] = from < 0 ? 0 : soften(frame[from] * level);
                if (magnitude(to[c]) > loudestOut) loudestOut = magnitude(to[c]);
            }
        }
        for (UInt32 n = frames * outChannels; n < outFrames * outChannels; n++) dst[n] = 0;
        if (!carried) { endGain = gain; endLimit = limit; carried = true; }
    }

    voice->gain = endGain;
    voice->limit = endLimit;
    atomic_fetch_add_explicit(&voice->cycles, 1, memory_order_relaxed);
    if (!heard) atomic_fetch_add_explicit(&voice->silentCycles, 1, memory_order_relaxed);
    // Only this thread raises them; a reader's reset in between just loses one cycle's peak.
    if (loudestIn > atomic_load_explicit(&voice->inputPeak, memory_order_relaxed))
        atomic_store_explicit(&voice->inputPeak, loudestIn, memory_order_relaxed);
    if (loudestOut > atomic_load_explicit(&voice->outputPeak, memory_order_relaxed))
        atomic_store_explicit(&voice->outputPeak, loudestOut, memory_order_relaxed);
    return noErr;
}
