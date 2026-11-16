#!/usr/bin/env python3
"""Write Cado's Sparkle appcast with one release's item on top (#24).

Called by scripts/release.sh after the DMG is notarized and verified. Items from
the base appcast (normally the one currently published on GitHub) are kept, minus
any for the same version, so the feed carries the release history.

Refuses (exit 1, nothing written) a build Sparkle couldn't offer:
- the build number is already in the feed under another version (e.g. two
  releases from one HEAD: the older item would be dropped and Sparkle, comparing
  builds, would never offer the newer one);
- the build isn't greater than the newest build in the feed (re-running the
  same version and build replaces its item).

Usage:
  make_appcast.py --out dist/appcast.xml [--base published.xml]
                  --version 0.2.0 --build 157 --min-os 14.0
                  --url https://.../Cado-0.2.0.dmg --length 12345
                  --signature <EdDSA base64> --notes-url https://.../releases/tag/v0.2.0
  make_appcast.py --check [--base published.xml] --version 0.2.0 --build 157
                  (release.sh's preflight: only the refusals above, writes nothing)

Tests: python3 -m unittest discover -s scripts/tests
"""
import argparse
import email.utils
import os
import sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DC = "http://purl.org/dc/elements/1.1/"
ET.register_namespace("sparkle", SPARKLE)
ET.register_namespace("dc", DC)


def sp(tag):
    return f"{{{SPARKLE}}}{tag}"


def new_feed():
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Cado"
    ET.SubElement(channel, "link").text = "https://github.com/ropats16/cado"
    ET.SubElement(channel, "description").text = "Cado updates"
    ET.SubElement(channel, "language").text = "en"
    return rss


def build_number(item):
    raw = item.findtext(sp("version"))
    try:
        return int(raw)
    except (TypeError, ValueError):
        sys.exit(f"error: appcast item {item.findtext(sp('shortVersionString'))!r} has a non-integer build {raw!r}")


def check(channel, version, build):
    """Exits with an error unless Sparkle would offer `build` over the feed."""
    for item in channel.findall("item"):
        other = item.findtext(sp("shortVersionString"))
        if build_number(item) == build and other != version:
            sys.exit(f"error: build {build} is already in the appcast as version {other}; "
                     "commit something new (or set CADO_BUILD) so this release gets its own build number")
    others = [build_number(i) for i in channel.findall("item")
              if not (build_number(i) == build and i.findtext(sp("shortVersionString")) == version)]
    if others and build <= max(others):
        sys.exit(f"error: build {build} isn't newer than the appcast's newest build {max(others)}; "
                 "Sparkle would never offer it")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--check", action="store_true", help="only validate version/build against --base")
    for name in ("version", "build"):
        p.add_argument(f"--{name}", required=True)
    for name in ("out", "min-os", "url", "length", "signature", "notes-url"):
        p.add_argument(f"--{name}")
    p.add_argument("--base")
    a = p.parse_args()
    try:
        build = int(a.build)
    except ValueError:
        sys.exit(f"error: --build {a.build!r} is not an integer")
    missing = [n for n in ("out", "min_os", "url", "length", "signature", "notes_url") if getattr(a, n) is None]
    if missing and not a.check:
        p.error("missing: " + ", ".join("--" + n.replace("_", "-") for n in missing))

    if a.base and os.path.getsize(a.base) > 0:
        rss = ET.parse(a.base).getroot()
        if rss.tag != "rss" or rss.find("channel") is None:
            sys.exit(f"error: {a.base} is not an RSS appcast")
    else:
        rss = new_feed()
    channel = rss.find("channel")

    check(channel, a.version, build)
    if a.check:
        print(f"appcast: version {a.version} build {build} can be released over the feed")
        return

    for item in channel.findall("item"):
        if item.findtext(sp("shortVersionString")) == a.version:
            channel.remove(item)

    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Cado {a.version}"
    ET.SubElement(item, "pubDate").text = email.utils.formatdate(usegmt=True)
    ET.SubElement(item, sp("version")).text = a.build
    ET.SubElement(item, sp("shortVersionString")).text = a.version
    ET.SubElement(item, sp("minimumSystemVersion")).text = a.min_os
    ET.SubElement(item, sp("fullReleaseNotesLink")).text = a.notes_url
    ET.SubElement(item, "enclosure", {
        "url": a.url,
        "length": a.length,
        "type": "application/octet-stream",
        sp("edSignature"): a.signature,
    })
    # Newest first, after the channel's own elements.
    first = next((i for i, child in enumerate(channel) if child.tag == "item"), len(channel))
    channel.insert(first, item)

    ET.indent(rss, space="  ")
    tmp = a.out + ".tmp"
    ET.ElementTree(rss).write(tmp, encoding="utf-8", xml_declaration=True)
    with open(tmp, "a") as f:
        f.write("\n")
    os.replace(tmp, a.out)
    print(f"appcast: {a.out} ({len(channel.findall('item'))} item(s), newest {a.version} build {a.build})")


if __name__ == "__main__":
    main()
