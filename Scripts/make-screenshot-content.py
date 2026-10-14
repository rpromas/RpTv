#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Writes playlist.m3u and guide.xml into a directory, for UITests/ScreenshotUITests (run by Scripts/screenshots.sh).

The playlist is Support/demo-playlist.m3u with a guide URL added, so the screenshots show only the demo content.
The guide gives each demo channel made-up programmes from a day before now to a day after.

    Scripts/make-screenshot-content.py /tmp/rptv-shots 8765
"""
import os, re, sys, time
from datetime import datetime, timezone
from xml.sax.saxutils import escape

out = sys.argv[1]
port = sys.argv[2] if len(sys.argv) > 2 else "8765"
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
hour = 3600
now = int(time.time())
start = (now // hour) * hour - 24 * hour
end = start + 48 * hour

with open(os.path.join(root, "Support", "demo-playlist.m3u")) as f:
    playlist = f.read()
playlist = playlist.replace("#EXTM3U", f'#EXTM3U url-tvg="http://127.0.0.1:{port}/guide.xml"', 1)
ids = list(dict.fromkeys(re.findall(r'tvg-id="([^"]+)"', playlist)))
os.makedirs(out, exist_ok=True)
with open(os.path.join(out, "playlist.m3u"), "w") as f:
    f.write(playlist)

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

with open(os.path.join(out, "guide.xml"), "w") as xml:
    xml.write('<?xml version="1.0" encoding="UTF-8"?>\n<tv>\n')
    for cid in ids:
        xml.write(f'<channel id="{cid}"><display-name>{cid}</display-name></channel>\n')
    for i, cid in enumerate(ids):
        # Stagger the channels so the grid doesn't line up in columns.
        t, n = start - (i % 3) * 15 * 60, i
        while t < end:
            title, minutes, desc, category = shows[n % len(shows)]
            xml.write(f'<programme start="{ts(t)}" stop="{ts(t + minutes * 60)}" channel="{cid}">'
                      f'<title>{escape(title)}</title><desc>{escape(desc)}</desc>'
                      f'<category>{category}</category></programme>\n')
            t += minutes * 60
            n += 1
    xml.write("</tv>\n")
print(f"Wrote {out}/playlist.m3u and {out}/guide.xml for port {port}")
