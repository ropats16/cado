#pragma once
// Stands in for ggml/src/ggml-version.h, which cmake generates from
// ggml-version.h.in. Keep in step with the whisper.cpp submodule pin
// (ggml/CMakeLists.txt GGML_VERSION; the pinned commit), see
// plans/IMPLEMENTATION-NOTES.md "Bumping whisper.cpp".
#define GGML_VERSION "0.26.0"
#define GGML_COMMIT  "d1be6fd"
