#!/usr/bin/env python3
"""Build Resources/AppIcon.icns: the idle avocado (plans/mascot/avocado-v3-idle.svg,
the art's single source of truth) on a macOS-grid rounded square.

macOS icon grid (1024 canvas): an 824x824 body inset 100 px, corner radius
185.4, with a soft drop shadow in the margin. Each iconset size is rendered
straight from SVG (rsvg-convert), so small sizes are crisp, then packed with
iconutil. Re-run after changing the art or the background: `make brand`.

Usage: python3 scripts/make_app_icon.py [--background yellow] [--png DIR]
  --png DIR   also write the 1024 master + iconset PNGs to DIR (for review)
"""
import argparse
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ART = ROOT / "plans/mascot/avocado-v3-idle.svg"
OUT = ROOT / "Resources/AppIcon.icns"
RSVG = shutil.which("rsvg-convert") or "/opt/homebrew/bin/rsvg-convert"

# Top / bottom of the body's soft vertical gradient: pastel yellow (the
# owner's pick over the earlier pink), which keeps the green avocado readable.
BACKGROUNDS = {
    "yellow": ("#fffbe3", "#ffe99a"),
}

# The idle art's drawn extent in its own units, from its paths: x0, y0, x1, y1.
FULL_BOX = (4.7, 12.5, 115.3, 126.7)   # hands to feet
BODY_BOX = (15.5, 12.5, 104.5, 117.5)  # the outlined body alone
FULL_HEIGHT = 600   # px of the 1024 canvas the whole avocado spans
BODY_HEIGHT = 660   # small sizes: the body alone, bigger
FULL_DROP = 6       # nudge down to the optical centre (the feet are light)
# At 16-32 px the thin hands and legs are noise, so those sizes drop them
# and enlarge the body (Apple's own icons simplify small sizes the same way).
SMALL_MAX_PX = 32


def art_body(svg: str, limbs: bool) -> str:
    """The art's drawing, without its <svg> wrapper and <title> (or limbs)."""
    inner = re.search(r"<svg[^>]*>(.*)</svg>", svg, re.S).group(1)
    inner = re.sub(r"<title>.*?</title>", "", inner, flags=re.S)
    if not limbs:   # each limb group holds exactly two child groups
        for group in ("legs", "hands"):
            inner = re.sub(rf'<g id="{group}">(<g id="[a-z-]+">.*?</g>){{2}}</g>', "", inner, flags=re.S)
        assert 'id="legs"' not in inner and 'id="hands"' not in inner, "art's limb groups changed"
    return inner


def icon_svg(background: str, small: bool = False) -> str:
    top, bottom = BACKGROUNDS[background]
    x0, y0, x1, y1 = BODY_BOX if small else FULL_BOX
    s = (BODY_HEIGHT if small else FULL_HEIGHT) / (y1 - y0)
    tx = 512 - s * (x0 + x1) / 2
    ty = 512 + (0 if small else FULL_DROP) - s * (y0 + y1) / 2
    feet_y = ty + s * 125.5
    ground = "" if small else (f'<ellipse cx="512" cy="{feet_y:.1f}" rx="{s * 34:.1f}" ry="{s * 4.5:.1f}" '
                               'fill="#3b2a22" opacity=".14" filter="url(#soft)"/>')
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="{top}"/><stop offset="1" stop-color="{bottom}"/>
  </linearGradient>
  <filter id="drop" x="-10%" y="-10%" width="120%" height="125%">
    <feGaussianBlur in="SourceAlpha" stdDeviation="14"/>
    <feOffset dy="12"/>
    <feComponentTransfer><feFuncA type="linear" slope=".28"/></feComponentTransfer>
    <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge>
  </filter>
  <filter id="soft"><feGaussianBlur stdDeviation="10"/></filter>
</defs>
<rect x="100" y="100" width="824" height="824" rx="185.4" fill="url(#bg)" filter="url(#drop)"/>
{ground}
<g transform="translate({tx:.2f} {ty:.2f}) scale({s:.4f})">{art_body(ART.read_text(), limbs=not small)}</g>
</svg>
"""


# iconutil's names and pixel sizes: 16-512 pt at 1x and 2x.
SIZES = [(f"icon_{pt}x{pt}{suffix}.png", pt * k)
         for pt in (16, 32, 128, 256, 512) for suffix, k in (("", 1), ("@2x", 2))]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--background", choices=BACKGROUNDS, default="yellow")
    ap.add_argument("--png", type=Path)
    args = ap.parse_args()

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        master, small = tmp / "icon.svg", tmp / "icon-small.svg"
        master.write_text(icon_svg(args.background))
        small.write_text(icon_svg(args.background, small=True))
        iconset = tmp / "AppIcon.iconset"
        iconset.mkdir()
        for name, px in SIZES:
            svg = small if px <= SMALL_MAX_PX else master
            subprocess.run([RSVG, "-w", str(px), "-h", str(px), str(svg), "-o", str(iconset / name)], check=True)
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(OUT)], check=True)
        if args.png:
            args.png.mkdir(parents=True, exist_ok=True)
            for svg in (master, small):
                shutil.copy(svg, args.png / f"{args.background}-{svg.name}")
            for name, _ in SIZES:
                shutil.copy(iconset / name, args.png / f"{args.background}-{name}")
    print(f"Wrote {OUT}")


if __name__ == "__main__":
    main()
