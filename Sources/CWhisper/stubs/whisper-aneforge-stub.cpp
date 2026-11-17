// whisper.cpp v1.9.5 can run its encoder through "ANEForge" when ANEFORGE_ENCODER
// is set in the environment; that backend dlopen()s a dylib named by another
// environment variable (src/aneforge/whisper-aneforge.cpp). Cado never uses it,
// so it is not compiled: these stubs satisfy the linker and report "not available"
// (init returns null). NOTE: with ANEFORGE_ENCODER set, whisper_init_state then
// logs an error and returns null, so the model FAILS TO LOAD (no Metal fallback).
// Unset it. The header include makes a signature change upstream a compile error.
#include "../whisper.cpp/src/aneforge/whisper-aneforge.h"
#include <stdint.h>

extern "C" {
struct whisper_aneforge_context * whisper_aneforge_init(const char *) { return nullptr; }

void whisper_aneforge_encode(struct whisper_aneforge_context *, int64_t, int64_t, const float *, float *) {}

void whisper_aneforge_free(struct whisper_aneforge_context *) {}
}
