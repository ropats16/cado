#!/usr/bin/env bash
# Speaker-bleed bench (#36): runs `Cado --meeting-test` over the fixtures from
# scripts/make_bleed_fixtures.py and prints one TSV row per meeting with each
# side's word error rate. Bleed that reaches the note shows up as Me
# insertions; me-clean is the headphones case. c1 (a conversation, from
# macOS `say`) is run too when it was made. Notes and logs go to
# .bench/bleed/out. Each run is ~1 min of audio (a few seconds on Apple Silicon).
#
# Usage: scripts/bleed_bench.sh [<Cado binary>] [<engine>:<model file> ...]
#   default binary: .build/release/Cado
#   default engines: whisper with ggml-small.en-q5_1 and ggml-tiny.en, and
#   parakeet with its installed model ("parakeet:")
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${1:-$ROOT/.build/release/Cado}"
[ $# -gt 0 ] && shift
MODELS="$HOME/Library/Application Support/Cado/models"
ENGINES=("$@")
[ ${#ENGINES[@]} -eq 0 ] && ENGINES=("whisper:$MODELS/ggml-small.en-q5_1.bin" "whisper:$MODELS/ggml-tiny.en.bin" "parakeet:")
DIR="$ROOT/.bench/bleed"
OUT="$DIR/out"
mkdir -p "$OUT"

printf "engine\tmeeting\tmic\tMe WER\tOthers WER\n"
for engine in "${ENGINES[@]}"; do
  id="${engine%%:*}"; model="${engine#*:}"
  name="$id-$(basename "${model:-default}" .bin)"
  for meeting in f1 f2 c1; do
    [ -d "$DIR/$meeting" ] || continue
    for mic in clean bleed-0.25 bleed-0.5; do
      tag="$name-$meeting-$mic"
      args=(--meeting-test --me "$DIR/$meeting/me-$mic.wav" --them "$DIR/$meeting/them.wav" --engine "$id"
            --notes "$OUT/notes-$tag" --me-reference "$(cat "$DIR/$meeting/me.txt")"
            --them-reference "$(cat "$DIR/$meeting/them.txt")")
      [ -n "$model" ] && args+=(--model "$model")
      rm -rf "$OUT/notes-$tag"
      "$BIN" "${args[@]}" > "$OUT/$tag.md" 2> "$OUT/$tag.log" || true
      me=$(sed -n 's/.*Me WER: //p' "$OUT/$tag.log")
      them=$(sed -n 's/.*Others WER: //p' "$OUT/$tag.log")
      printf "%s\t%s\t%s\t%s\t%s\n" "$name" "$meeting" "$mic" "${me:-failed}" "${them:-failed}"
    done
  done
done
