#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Writes Support/demo-guide.xml.gz, the made-up TV guide that Support/demo-playlist.m3u points to (url-tvg).

App Review and TestFlight testers load the playlist from GitHub, so the guide is a static file: it covers the
channels of the demo playlist from the first of this month for MONTHS months (default 15). Run it again before
it runs out (the release checklist in docs/app-store.md says when). The output is the same for the same month.

    Scripts/make-sample-guide.py [MONTHS]
"""
import calendar, gzip, os, re, sys
from datetime import datetime, timezone
from xml.sax.saxutils import escape

months = int(sys.argv[1]) if len(sys.argv) > 1 else 15
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
today = datetime.now(timezone.utc)
first = datetime(today.year, today.month, 1, tzinfo=timezone.utc)
y, m = divmod(today.month - 1 + months, 12)
last = datetime(today.year + y, m + 1, 1, tzinfo=timezone.utc)
start, end = calendar.timegm(first.timetuple()), calendar.timegm(last.timetuple())

with open(os.path.join(root, "Support", "demo-playlist.m3u")) as f:
    entries = re.findall(r'#EXTINF:[^\n]*tvg-id="([^"]+)"[^\n]*group-title="([^"]+)"', f.read())
# Only live channels get a guide.
ids = list(dict.fromkeys(cid for cid, group in entries if group != "Movies"))

shows = [
    ("Morning Test Card", 60, "Colour bars and a steady tone to start the day.", "Technology"),
    ("BipBop Live", 30, "The classic sample stream, at every bitrate the encoder offers.", "Technology"),
    ("Encoder Hour", 90, "A look at how one picture becomes many renditions.", "Documentary"),
    ("Frame Rate Stories", 45, "Twenty-four, thirty, sixty: what each one feels like.", "Documentary"),
    ("Sync Check", 30, "Sound and picture, side by side, frame by frame.", "Technology"),
    ("Evening Showcase", 60, "Sample streams in high dynamic range and spatial audio.", "Entertainment"),
    ("Night Bars", 120, "Quiet colour bars until morning.", "Entertainment"),
]

def ts(t):
    return datetime.fromtimestamp(t, timezone.utc).strftime("%Y%m%d%H%M%S +0000")

path = os.path.join(root, "Support", "demo-guide.xml.gz")
# mtime=0 keeps the file byte-identical when nothing changed.
with open(path, "wb") as raw, gzip.GzipFile(fileobj=raw, mode="wb", mtime=0, compresslevel=9) as gz:
    def write(s): gz.write(s.encode())
    write('<?xml version="1.0" encoding="UTF-8"?>\n<tv generator-info-name="RpTv sample guide">\n')
    for cid in ids:
        write(f'<channel id="{cid}"><display-name>{cid}</display-name></channel>\n')
    for i, cid in enumerate(ids):
        # Stagger the channels so the grid doesn't line up in columns.
        t, n = start - (i % 3) * 15 * 60, i
        while t < end:
            title, minutes, desc, category = shows[n % len(shows)]
            write(f'<programme start="{ts(t)}" stop="{ts(t + minutes * 60)}" channel="{cid}">'
                  f'<title>{escape(title)}</title><desc>{escape(desc)}</desc>'
                  f'<category>{category}</category></programme>\n')
            t += minutes * 60
            n += 1
    write("</tv>\n")
print(f"Wrote {path}: {len(ids)} channels, {first:%Y-%m-%d} to {last:%Y-%m-%d} ({os.path.getsize(path) // 1024} KB)")
