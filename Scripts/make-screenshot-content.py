#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Writes playlist.m3u and guide.xml.gz into a directory, for UITests/ScreenshotUITests (run by Scripts/screenshots.sh).

The playlist is Support/demo-playlist.m3u with its guide URL pointed at the local server, and the guide is
Support/demo-guide.xml.gz (Scripts/make-sample-guide.py), so the screenshots show what App Review sees.

    Scripts/make-screenshot-content.py /tmp/rptv-shots 8765
"""
import os, re, shutil, sys

out = sys.argv[1]
port = sys.argv[2] if len(sys.argv) > 2 else "8765"
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

with open(os.path.join(root, "Support", "demo-playlist.m3u")) as f:
    playlist = f.read()
playlist = re.sub(r'url-tvg="[^"]*"', f'url-tvg="http://127.0.0.1:{port}/guide.xml.gz"', playlist, count=1)
os.makedirs(out, exist_ok=True)
with open(os.path.join(out, "playlist.m3u"), "w") as f:
    f.write(playlist)
shutil.copy(os.path.join(root, "Support", "demo-guide.xml.gz"), os.path.join(out, "guide.xml.gz"))
print(f"Wrote {out}/playlist.m3u and {out}/guide.xml.gz for port {port}")
