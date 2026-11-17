#!/usr/bin/env bash
# Synthesize a small Hindi + English meeting fixture (#47) with macOS `say`,
# offline: no downloads, no third-party services. Needs the Hindi voice
# "Lekha" (hi_IN) and an Indian-English voice (Rishi/Aman/Tara, en_IN) to be
# installed already; this script never installs voices (that's a System
# Settings change — the owner does it, if at all).
#
# Writes to .bench/fixtures/mixed-hi-en/ (or $1):
#   me.wav, them.wav          16 kHz mono 16-bit, one side each, for
#                             `Cado --meeting-test --me me.wav --them them.wav`
#   s-*.wav                   every sentence on its own (one "chunk" each)
#   conversation.wav          me + them back to back (one long job)
#   manifest.tsv              for `Cado --bench --manifest …`: each sentence
#                             as `short`, the conversation as `long`
#   reference-me.txt, reference-them.txt   the known text, per side
#
# Usage: [GAP_SECONDS=1.2] scripts/make_mixed_language_fixture.sh [out-dir]
#   GAP_SECONDS below 0.6 (e.g. 0.3) joins a side's sentences into one long
#   passage, as in quick conversation: the per-passage language limit.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/.bench/fixtures/mixed-hi-en}"
HINDI_VOICE="${HINDI_VOICE:-Lekha}"

have_voice() { say -v '?' | awk '{print $1}' | grep -qx "$1"; }
if ! have_voice "$HINDI_VOICE"; then
  echo "error: the Hindi voice \"$HINDI_VOICE\" isn't installed. Add it in System Settings ›" \
       "Accessibility › Spoken Content › System Voice › Manage Voices (an owner step), or set HINDI_VOICE." >&2
  exit 1
fi
EN_ME=Rishi; EN_THEM=Aman
have_voice "$EN_ME" || EN_ME=Samantha
have_voice "$EN_THEM" || EN_THEM=Samantha

mkdir -p "$OUT"
rm -f "$OUT"/s-*.wav "$OUT"/reference-*.txt

# side<TAB>voice-kind<TAB>text. "mix" = one sentence that switches language
# mid-way (Hinglish), read by the Hindi voice: the known per-chunk limit.
IFS= read -r -d '' SCRIPT <<'EOF' || true
me	hi	नमस्ते, आज की मीटिंग में हम नए प्रोजेक्ट के बारे में बात करेंगे।
me	en	First, let's go over the timeline for the next release.
me	hi	मुझे लगता है कि हमें अगले हफ्ते तक डिज़ाइन पूरा कर लेना चाहिए।
me	en	Can you share the latest numbers from the sales team?
me	mix	हमें client को Friday तक report भेजनी है।
them	en	Sure, the sales numbers look good this quarter.
them	hi	पिछले महीने की तुलना में बिक्री बीस प्रतिशत बढ़ी है।
them	en	We should also plan a review meeting with the client.
them	hi	ठीक है, मैं कल सुबह सबको ईमेल भेज दूँगा।
EOF

: > "$OUT/reference-me.txt"; : > "$OUT/reference-them.txt"
{
  echo "# Hindi + English fixture (#47), from scripts/make_mixed_language_fixture.sh"
  i=0
  while IFS=$'\t' read -r side kind text; do
    [[ -n "$side" ]] || continue
    i=$((i + 1))
    case "$kind" in
      hi|mix) voice="$HINDI_VOICE" ;;
      *) if [[ "$side" == me ]]; then voice="$EN_ME"; else voice="$EN_THEM"; fi ;;
    esac
    file="s-$(printf %02d "$i")-$side-$kind.wav"
    say -v "$voice" -o "$OUT/$file" --data-format=LEI16@16000 "$text"
    printf 'short\t%s\t%s\n' "$file" "$text"
    printf '%s\n' "$text" >> "$OUT/reference-$side.txt"
  done <<< "$SCRIPT"
} > "$OUT/manifest.tsv"

# Join the sentences per side with 1.2 s pauses (GAP_SECONDS; the chunker cuts at
# pauses of 0.6 s or more), and
# both sides back to back for the single long job. Stdlib only.
python3 -I - "$OUT" "${GAP_SECONDS:-1.2}" <<'PY'
import sys, wave, glob, os
out = sys.argv[1]
def frames(path):
    with wave.open(path) as w:
        assert w.getframerate() == 16000 and w.getnchannels() == 1 and w.getsampwidth() == 2, path
        return w.readframes(w.getnframes())
gap = b"\0\0" * int(16000 * float(sys.argv[2]))
def write(name, parts):
    with wave.open(os.path.join(out, name), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
        w.writeframes(gap.join(parts) + gap)
sides = {}
for path in sorted(glob.glob(os.path.join(out, "s-*.wav"))):
    side = os.path.basename(path).split("-")[2]
    sides.setdefault(side, []).append(frames(path))
write("me.wav", sides["me"])
write("them.wav", sides["them"])
write("conversation.wav", sides["me"] + sides["them"])
PY

conversation="$(cat "$OUT/reference-me.txt" "$OUT/reference-them.txt" | tr '\n' ' ')"
printf 'long\tconversation.wav\t%s\n' "$conversation" >> "$OUT/manifest.tsv"
echo "Wrote $OUT (voices: $HINDI_VOICE, $EN_ME, $EN_THEM)"
