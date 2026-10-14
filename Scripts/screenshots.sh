#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Takes the App Store screenshots on the iPhone 6.9" and iPad 13" simulators, from the demo playlist only.
#
# Usage: Scripts/screenshots.sh [output directory, default build/screenshots]
#
# Serves the demo playlist with a made-up guide (Scripts/make-screenshot-content.py), sets a clean status bar
# and dark mode, runs UITests/ScreenshotUITests on each simulator, and saves its attachments as
# <output>/<device>/<n> <screen>.png. Needs an iPhone 17 Pro Max and an iPad Pro 13-inch (M5) simulator.

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-"$ROOT/build/screenshots"}
WORK="$ROOT/build/screenshot-run"
PORT=8765
DEVICES="iPhone 17 Pro Max
iPad Pro 13-inch (M5)"

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK/content" "$OUT"
"$ROOT/Scripts/make-screenshot-content.py" "$WORK/content" "$PORT"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/content" > "$WORK/server.log" 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT INT TERM

cd "$ROOT"
xcodegen generate --quiet

echo "$DEVICES" | while read -r device; do
    udid=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
for runtime, devices in json.load(sys.stdin)["devices"].items():
    for d in devices:
        if d["name"] == name and "iOS" in runtime:
            print(d["udid"]); sys.exit()
' "$device")
    if [ -z "$udid" ]; then
        echo "No \"$device\" simulator. Create one in Xcode > Window > Devices and Simulators." >&2
        exit 1
    fi
    echo "==> $device"
    xcrun simctl boot "$udid" 2>/dev/null || true
    xcrun simctl bootstatus "$udid" > /dev/null
    xcrun simctl ui "$udid" appearance dark
    xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
        --cellularMode active --cellularBars 4 --operatorName "" --batteryState charged --batteryLevel 100

    result="$WORK/$udid.xcresult"
    status=0
    TEST_RUNNER_RPTV_SCREENSHOT_PLAYLIST_URL="http://127.0.0.1:$PORT/playlist.m3u" \
        xcodebuild -project RpTv.xcodeproj -scheme RpTv -destination "id=$udid" \
        -only-testing:RpTvUITests/ScreenshotUITests -resultBundlePath "$result" test -quiet < /dev/null || status=$?

    xcrun xcresulttool export attachments --path "$result" --output-path "$WORK/$udid"
    mkdir -p "$OUT/$device"
    python3 - "$WORK/$udid" "$OUT/$device" <<'EOF'
import json, os, re, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
for test in json.load(open(os.path.join(src, "manifest.json"))):
    for a in test["attachments"]:
        # "1 Live TV_0_<UUID>.png" → "1 Live TV.png". Skips what XCTest attaches on a failure.
        match = re.fullmatch(r"(\d+ .+)_\d+_[0-9A-F-]{36}\.png", a["suggestedHumanReadableName"])
        if not match:
            continue
        name = match[1] + ".png"
        shutil.copy(os.path.join(src, a["exportedFileName"]), os.path.join(dst, name))
        print("   ", os.path.join(dst, name))
EOF
    xcrun simctl status_bar "$udid" clear
    if [ "$status" -ne 0 ]; then
        echo "ScreenshotUITests failed on $device. The result bundle is $result." >&2
        exit "$status"
    fi
done
