#!/usr/bin/env python3
"""Builds speaker-bleed meeting fixtures (#36) from the bench's short clips.

usage: python3 scripts/make_bleed_fixtures.py [<bench fixtures dir> [<out dir>]]
       (defaults: .bench/fixtures, .bench/bleed; run fetch_bench_fixtures.sh first)

Writes two meetings, f1 and f2 (the same eight clips with the sides
swapped), each ~58 s: four turns per side, one Me turn starting 1.5 s before
Others finishes (talking over). Per meeting: them.wav; me-clean.wav (as with
headphones); me-bleed-0.25.wav and me-bleed-0.5.wav (laptop speakers: Others
mixed into the mic at -12 / -6 dB, 40 ms late, with room reflections at 75
and 120 ms, low-passed at ~3 kHz); a -55 dBFS noise floor on Me; me.txt and
them.txt, each side's reference text. 16 kHz mono int16. Deterministic.
Stock python3 only.
"""
import array, math, os, random, sys, wave

root = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
fixtures = sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, ".bench", "fixtures")
dest = sys.argv[2] if len(sys.argv) > 2 else os.path.join(root, ".bench", "bleed")
src = os.path.join(fixtures, "short")
RATE = 16000
manifest = {}
for line in open(os.path.join(fixtures, "manifest.tsv")):
    if line.startswith("#"):
        continue
    kind, path, ref = line.rstrip("\n").split("\t")
    if kind == "short":
        manifest[os.path.basename(path)] = ref

def load(name):
    w = wave.open(os.path.join(src, name))
    assert w.getframerate() == RATE and w.getnchannels() == 1
    a = array.array("h", w.readframes(w.getnframes()))
    return [x / 32768 for x in a]

def build(out, swap):
    A = ["2830-3980-0000.wav", "4446-2271-0000.wav", "61-70968-0000.wav", "260-123286-0000.wav"]
    B = ["3570-5694-0001.wav", "7176-92135-0001.wav", "2961-960-0007.wav", "jfk.wav"]
    me_clips, them_clips = (B, A) if swap else (A, B)

    # Turns alternate Me, Others, ...; the third Me turn starts 1.5 s before the
    # Others turn before it ends (talking over).
    t = 1.0
    placed = []  # (side, clip, start)
    for i in range(4):
        for side, clips in (("me", me_clips), ("them", them_clips)):
            clip = clips[i]
            n = len(load(clip)) / RATE
            start = t
            if side == "me" and i == 2:
                start = t - 1.0 - 1.5
            placed.append((side, clip, start))
            t = max(t, start + n) + 1.0
    total = int((t + 1.0) * RATE)

    def track(side):
        buf = [0.0] * total
        for s, clip, start in placed:
            if s != side:
                continue
            x = load(clip)
            o = int(start * RATE)
            for k, v in enumerate(x):
                buf[o + k] += v
        return buf

    me, them = track("me"), track("them")

    def write(name, x):
        w = wave.open(os.path.join(out, name), "wb")
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes(array.array("h", (max(-32767, min(32767, int(v * 32767))) for v in x)).tobytes())

    os.makedirs(out, exist_ok=True)
    write("them.wav", them)
    random.seed(36)
    noise = [random.gauss(0, 10 ** (-55 / 20)) for _ in range(total)]
    write("me-clean.wav", [m + n for m, n in zip(me, noise)])

    # Room: direct path at 40 ms, reflections at 75 ms (-6 dB) and 120 ms (-12 dB),
    # then a one-pole low-pass (~3 kHz): laptop speakers into the laptop mic.
    taps = [(int(0.040 * RATE), 1.0), (int(0.075 * RATE), 0.5), (int(0.120 * RATE), 0.25)]
    room = [0.0] * total
    for d, g in taps:
        for k in range(d, total):
            room[k] += g * them[k - d]
    alpha = 1 - math.exp(-2 * math.pi * 3000 / RATE)
    y = 0.0
    for k in range(total):
        y += alpha * (room[k] - y)
        room[k] = y
    for gain in (0.25, 0.5):
        write(f"me-bleed-{gain}.wav", [m + gain * r + n for m, r, n in zip(me, room, noise)])

    for side, clips in (("me", me_clips), ("them", them_clips)):
        order = sorted((st, c) for s, c, st in placed if s == side)
        open(os.path.join(out, f"{side}.txt"), "w").write(" ".join(manifest[c] for _, c in order))
    print(f"{out}: {total / RATE:.1f} s", file=sys.stderr)


for name, swap in (("f1", False), ("f2", True)):
    build(os.path.join(dest, name), swap)
