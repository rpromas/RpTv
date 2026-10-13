#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Writes playlist.m3u and guide.xml into a directory, for UITests/GuideUITests and for trying the guide grid.

1,000 channels with 7 days of guide on either side of now, plus:
- "Reminder Test": 2-minute programmes titled by their UTC start ("Reminder 1234Z").
- "Catch-up Shift" / "Catch-up Archive": catch-up channels with an "Earlier … Show" three hours ago. The archive
  channel's catch-up URL points back at the server, so its log shows the URL the player asked for.

Streams are Apple's public sample stream. Serve the directory on the port given (default 8765):

    Scripts/make-demo-guide.py /tmp/rptv-guide
    python3 -m http.server 8765 --directory /tmp/rptv-guide
"""
import sys, time
from datetime import datetime, timezone

out = sys.argv[1]
port = sys.argv[2] if len(sys.argv) > 2 else "8765"
base = f"http://127.0.0.1:{port}"
bipbop = "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8"
now = int(time.time())
hour = 3600
start_all = (now // hour) * hour - 7 * 24 * hour
end_all = start_all + 14 * 24 * hour

def ts(t): return datetime.fromtimestamp(t, timezone.utc).strftime("%Y%m%d%H%M%S +0000")

specials = [
    ("reminder", "Reminder Test", ""),
    ("shift", "Catch-up Shift", 'catchup="shift" catchup-days="3"'),
    ("archive", "Catch-up Archive",
     f'catchup="default" catchup-days="3" catchup-source="{base}/archive/ch.m3u8?start={{utc}}&duration={{duration}}"'),
]
with open(f"{out}/playlist.m3u", "w") as m3u:
    m3u.write(f'#EXTM3U url-tvg="{base}/guide.xml"\n')
    for cid, name, extra in specials:
        m3u.write(f'#EXTINF:-1 tvg-id="{cid}" group-title="Specials" {extra},{name}\n{bipbop}\n')
    for i in range(1, 1001):
        m3u.write(f'#EXTINF:-1 tvg-id="ch{i:04}" group-title="Group {i % 10 + 1}",Channel {i:04}\n{bipbop}\n')

with open(f"{out}/guide.xml", "w") as xml:
    xml.write('<?xml version="1.0" encoding="UTF-8"?>\n<tv>\n')
    ids = [s[0] for s in specials] + [f"ch{i:04}" for i in range(1, 1001)]
    for cid in ids:
        xml.write(f'<channel id="{cid}"><display-name>{cid}</display-name></channel>\n')
    def prog(cid, s, e, title, desc=None):
        d = f"<desc>{desc}</desc>" if desc else ""
        xml.write(f'<programme start="{ts(s)}" stop="{ts(e)}" channel="{cid}"><title>{title}</title>{d}<category>Test</category></programme>\n')
    # 2-minute programmes named after their UTC start, so a test can pick one a few minutes ahead.
    t = (now // 120) * 120 - 6 * hour
    while t < now + 6 * hour:
        prog("reminder", t, t + 120, "Reminder " + datetime.fromtimestamp(t, timezone.utc).strftime("%H%MZ"))
        t += 120
    for cid in ("shift", "archive"):
        label = "Shift" if cid == "shift" else "Archive"
        t = start_all
        while t < end_all:
            title = f"Earlier {label} Show" if t == (now // hour) * hour - 3 * hour else f"{label} {datetime.fromtimestamp(t, timezone.utc):%a %H}h"
            prog(cid, t, t + hour, title, "A programme on a channel with catch-up.")
            t += hour
    for i in range(1, 1001):
        cid = f"ch{i:04}"
        t = start_all + (i % 4) * 15 * 60 - hour
        n = 0
        while t < end_all:
            length = [30, 60, 90, 45][(i + n) % 4] * 60
            prog(cid, t, t + length, f"Show {n} on {i:04}")
            t += length
            n += 1
    xml.write("</tv>\n")
print(f"Wrote {out}/playlist.m3u and {out}/guide.xml for {base}")
