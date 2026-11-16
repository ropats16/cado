#!/usr/bin/env python3
"""Write Cado's Sparkle appcast with one release's item on top (#24).

Called by scripts/release.sh after the DMG is notarized and verified. Items from
the base appcast (normally the one currently published on GitHub) are kept, minus
any for the same version or build, so the feed carries the release history.

Usage:
  make_appcast.py --out dist/appcast.xml [--base published.xml]
                  --version 0.2.0 --build 157 --min-os 14.0
                  --url https://.../Cado-0.2.0.dmg --length 12345
                  --signature <EdDSA base64> --notes-url https://.../releases/tag/v0.2.0
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


def main():
    p = argparse.ArgumentParser()
    for name in ("out", "version", "build", "min-os", "url", "length", "signature", "notes-url"):
        p.add_argument(f"--{name}", required=True)
    p.add_argument("--base")
    a = p.parse_args()

    if a.base and os.path.getsize(a.base) > 0:
        rss = ET.parse(a.base).getroot()
        if rss.tag != "rss" or rss.find("channel") is None:
            sys.exit(f"error: {a.base} is not an RSS appcast")
    else:
        rss = new_feed()
    channel = rss.find("channel")

    for item in channel.findall("item"):
        if item.findtext(sp("version")) == a.build or item.findtext(sp("shortVersionString")) == a.version:
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
