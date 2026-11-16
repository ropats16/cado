#pragma once
// Real-time IOProc for a private aggregate device that holds a Core Audio
// process tap (system audio): downmixes each input slice into a ring, and
// notes whether any non-zero sample has arrived. Nothing on the audio thread
// allocates, locks or blocks.
#include <CoreAudio/CoreAudio.h>
#include "audio_ring.h"

typedef struct vt_tap vt_tap;

/// State the IOProc writes through: pass it as the IOProc's client data.
/// Returns NULL on allocation failure.
vt_tap *vt_tap_create(vt_ring *ring);
/// Only call once the IOProc is destroyed (or its device is): then nothing
/// calls back into it.
void vt_tap_destroy(vt_tap *tap);

/// The `AudioDeviceIOProc`. Float32 input only (any channel layout, as
/// `vt_ring_write_downmix` takes); output is left untouched.
/// Nullability matches `AudioDeviceIOProc`, so Swift can pass it as one.
OSStatus vt_tap_io_proc(AudioObjectID device, const AudioTimeStamp *_Nonnull now,
                        const AudioBufferList *_Nonnull input, const AudioTimeStamp *_Nonnull input_time,
                        AudioBufferList *_Nonnull output, const AudioTimeStamp *_Nonnull output_time,
                        void *_Nullable client);

/// Frames delivered by the IOProc so far (any thread).
uint64_t vt_tap_frames(const vt_tap *tap);
/// 1 once any delivered sample was non-zero (any thread). A tap without the
/// system-audio permission delivers exact zeros, so this proves the grant.
int vt_tap_heard_sound(const vt_tap *tap);
