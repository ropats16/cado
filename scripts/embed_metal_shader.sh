#!/usr/bin/env bash
# Embed ggml's Metal shaders into the binary so they JIT-compile at runtime — no
# Metal toolchain (xcrun metal) needed at build time, and nothing to bundle into
# the .app. This mirrors whisper.cpp's own GGML_METAL_EMBED_LIBRARY build
# (ggml/src/ggml-metal/CMakeLists.txt): since whisper.cpp v1.9.5 the shader is one
# source per kind (kernels/*.metal, one MTLLibrary each); each is merged with the
# headers it includes + ggml-common.h + ggml-metal-impl.h, and an assembly file
# `.incbin`s the merged sources under ggml_metallib_<kind>_{start,end}.
#
# The kind list is read from CMakeLists.txt (METALLIB_KERNEL_SOURCES), so it
# follows the submodule.
#
# Outputs (gitignored build artifacts) into Sources/CWhisper/:
#   metal-embed/ggml-metal-embed-<kind>.metal   merged shader sources
#   ggml-metal-embed.s                          assembly exposing the symbols
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# On Intel (x86_64) the CPU build path is used (see Package.swift) and no Metal
# shader is needed, so skip the embed entirely — this makes make/setup/package
# work on Intel with no arch branching in the callers. Under Rosetta `uname -m`
# reports x86_64, which is exactly the CPU-build case we want to skip.
if [[ "$(uname -m)" == "x86_64" ]]; then
  echo "✓ skipping Metal shader embed on x86_64 (CPU-only build)"
  exit 0
fi

G="$ROOT/Sources/CWhisper/whisper.cpp/ggml/src"
M="$G/ggml-metal"
COMMON="$G/ggml-common.h"
IMPL="$M/ggml-metal-impl.h"
CMAKE="$M/CMakeLists.txt"
OUTDIR="$ROOT/Sources/CWhisper"
MERGED_DIR="$OUTDIR/metal-embed"
ASM="$OUTDIR/ggml-metal-embed.s"

if [[ ! -f "$CMAKE" ]]; then
  echo "error: $CMAKE not found. Run 'git submodule update --init' (or 'make setup')." >&2
  exit 1
fi

# kinds = kernels/<kind>.metal listed in METALLIB_KERNEL_SOURCES.
KINDS=()
while IFS= read -r kind; do KINDS+=("$kind"); done < <(
  sed -n '/^set(METALLIB_KERNEL_SOURCES/,/^)/p' "$CMAKE" | sed -n 's|^ *kernels/\(.*\)\.metal$|\1|p')
if ((${#KINDS[@]} == 0)); then
  echo "error: no kernels found in $CMAKE (METALLIB_KERNEL_SOURCES changed shape?)" >&2
  exit 1
fi

if [[ -f "$ASM" ]] && ! find "$M/kernels" "$COMMON" "$IMPL" "$CMAKE" "$0" -newer "$ASM" 2>/dev/null | grep -q .; then
  echo "✓ embedded Metal shader already up to date"
  exit 0
fi

echo "Embedding ${#KINDS[@]} Metal shader libraries (merge headers + .incbin; no toolchain)…"
rm -rf "$MERGED_DIR"
mkdir -p "$MERGED_DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

{
  echo ".section __DATA,__ggml_metallib"
  for kind in "${KINDS[@]}"; do
    src="$M/kernels/$kind.metal"
    merged="$MERGED_DIR/ggml-metal-embed-$kind.metal"
    # only prepend the headers this source actually includes (as the cmake does)
    headers=("$M/kernels/common.h")
    grep -q '#include "dequantize\.h"' "$src" && headers+=("$M/kernels/dequantize.h")
    grep -q '#include "quantize\.h"' "$src" && headers+=("$M/kernels/quantize.h")
    grep -q '#include "fa_common\.metal"' "$src" && headers+=("$M/kernels/fa_common.metal")
    grep -q '#include "fa_vec_common\.metal"' "$src" && headers+=("$M/kernels/fa_vec_common.metal")
    cat "${headers[@]}" "$src" > "$TMP/1"
    # drop the internal #includes and #pragma once
    sed -e '/#include "common.h"/d' -e '/#include "dequantize.h"/d' -e '/#include "quantize.h"/d' \
        -e '/#include "fa_common.metal"/d' -e '/#include "fa_vec_common.metal"/d' -e '/#pragma once/d' \
        < "$TMP/1" > "$TMP/2"
    # inline ggml-common.h at the placeholder, then ggml-metal-impl.h at its #include
    sed -e "/__embed_ggml-common.h__/r ${COMMON}" -e "/__embed_ggml-common.h__/d" < "$TMP/2" > "$TMP/3"
    sed -e "/#include \"ggml-metal-impl.h\"/r ${IMPL}" -e "/#include \"ggml-metal-impl.h\"/d" < "$TMP/3" > "$merged"
    # absolute path, like the upstream cmake build, so .incbin resolves regardless of compiler CWD
    echo ".globl _ggml_metallib_${kind}_start"
    echo "_ggml_metallib_${kind}_start:"
    echo ".incbin \"${merged}\""
    echo ".globl _ggml_metallib_${kind}_end"
    echo "_ggml_metallib_${kind}_end:"
  done
} > "$ASM"

echo "✓ Wrote ${#KINDS[@]} files in $MERGED_DIR"
echo "✓ Wrote $ASM"
