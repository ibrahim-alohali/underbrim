//
//  MixerRender.h
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The Sound page's audio path, on Core Audio's real-time thread. In C, so nothing on that thread
//  allocates, locks or waits (clang checks the render function for it).
//

#ifndef MixerRender_h
#define MixerRender_h

#include <CoreAudio/CoreAudio.h>
#include <stdint.h>

CF_ASSUME_NONNULL_BEGIN

/// One app's level and the render thread's state for it.
typedef struct MixerVoice MixerVoice;

/// A voice starting at `gain` (linear, 0 to 2), for a device running at `sampleRate`.
MixerVoice *_Nullable mixer_voice_create(double sampleRate, float gain);
/// Only once no IO proc renders with it any more.
void mixer_voice_destroy(MixerVoice *voice);
/// The level to glide to, from any thread.
void mixer_voice_set_gain(MixerVoice *voice, float gain);
uint64_t mixer_voice_cycles(const MixerVoice *voice);
uint64_t mixer_voice_silent_cycles(const MixerVoice *voice);
/// The loudest sample read from the tap and played since the last call, then starts again.
void mixer_voice_take_peaks(MixerVoice *voice, float *input, float *output);

/// The IO proc of an aggregate made of the output device and one tap; its client data is a voice.
OSStatus mixer_render(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
                      const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime,
                      void *_Nullable voice) CA_REALTIME_API;

CF_ASSUME_NONNULL_END

#endif
