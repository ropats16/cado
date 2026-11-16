#include "audio_tap.h"
#include <stdatomic.h>
#include <stdlib.h>

struct vt_tap {
    vt_ring *ring;
    _Atomic uint64_t frames;
    _Atomic int heard;
};

vt_tap *vt_tap_create(vt_ring *ring) {
    vt_tap *tap = calloc(1, sizeof *tap);
    if (!tap) return NULL;
    tap->ring = ring;
    atomic_init(&tap->frames, 0);
    atomic_init(&tap->heard, 0);
    return tap;
}

void vt_tap_destroy(vt_tap *tap) {
    free(tap);
}

/// Whether any sample in `buffers` is non-zero. Stops at the first one.
static int has_sound(const AudioBufferList *buffers) {
    for (uint32_t b = 0; b < buffers->mNumberBuffers; b++) {
        const AudioBuffer *buffer = &buffers->mBuffers[b];
        if (!buffer->mData) continue;
        const float *samples = buffer->mData;
        uint32_t count = buffer->mDataByteSize / (uint32_t)sizeof(float);
        for (uint32_t i = 0; i < count; i++) {
            if (samples[i] != 0.0f) return 1;
        }
    }
    return 0;
}

OSStatus vt_tap_io_proc(AudioObjectID device, const AudioTimeStamp *now,
                        const AudioBufferList *input, const AudioTimeStamp *input_time,
                        AudioBufferList *output, const AudioTimeStamp *output_time,
                        void *client) {
    (void)device; (void)now; (void)input_time; (void)output; (void)output_time;
    vt_tap *tap = client;
    if (!tap || !input || input->mNumberBuffers == 0) return noErr;
    const AudioBuffer *first = &input->mBuffers[0];
    if (first->mNumberChannels == 0) return noErr;
    uint32_t frames = first->mDataByteSize / (first->mNumberChannels * (uint32_t)sizeof(float));
    // The ring clamps to the shortest buffer and drops what doesn't fit.
    uint32_t written = vt_ring_write_downmix(tap->ring, input, frames);
    atomic_fetch_add_explicit(&tap->frames, written, memory_order_relaxed);
    if (!atomic_load_explicit(&tap->heard, memory_order_relaxed) && has_sound(input)) {
        atomic_store_explicit(&tap->heard, 1, memory_order_relaxed);
    }
    return noErr;
}

uint64_t vt_tap_frames(const vt_tap *tap) {
    return atomic_load_explicit(&((vt_tap *)tap)->frames, memory_order_relaxed);
}

int vt_tap_heard_sound(const vt_tap *tap) {
    return atomic_load_explicit(&((vt_tap *)tap)->heard, memory_order_relaxed);
}
