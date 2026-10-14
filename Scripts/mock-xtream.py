#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""A local Xtream Codes server with made-up channels, movies and series, for trying RpTv on a phone.

    Scripts/mock-xtream.py [--port 8080] [--extra-channels N]

Add an Xtream source in the app with the printed server address, username `demo` and password `demo`
(`expired`/`expired` logs in to an expired account). The same catalog is an M3U playlist at `get.php`.

What's in it:
- Live: H.264 720p, HEVC 1080p, interlaced 576i with MP2 audio, H.264 with AC-3 audio, and a channel that
  always fails. Each is a 2-minute loop served as a live HLS window (`.m3u8`) or a paced MPEG-TS stream
  (`.ts`), so the loop point is a timestamp discontinuity. `--extra-channels` adds filler channels.
- Guide: XMLTV (`xmltv.php`) and `get_short_epg`, 3 days back and 2 ahead. Neris News, Lagoon Sports SD and
  Pine Kids have catch-up; any archive request plays that channel's 2-minute loop.
- Movies: 6-minute MP4s, an MKV with English and Lithuanian audio and subtitles, and an HEVC MP4.
- Series: 2-minute MP4 episodes, enough to try Up Next and Continue Watching.

The first run renders the media with ffmpeg (Homebrew's is fine) and a small AppKit helper for the title cards,
into `.build/mock-xtream` at the repo root; later runs reuse it.
"""
import argparse, base64, hashlib, json, os, re, shutil, socket, subprocess, sys, time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse
from xml.sax.saxutils import escape

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(ROOT, ".build", "mock-xtream")
USERS = {"demo": ("demo", "Active"), "expired": ("expired", "Expired")}
SERVER_TZ = "Europe/Vilnius"
SEGMENT = 6          # seconds per live HLS segment
LIVE_LOOP = 120      # seconds of video per live channel
MOVIE_LENGTH = 360
EPISODE_LENGTH = 120
STARTED = int(time.time())

# MARK: - Catalog (all made up)

LIVE_CATEGORIES = [("1", "News"), ("2", "Sports"), ("3", "Kids"), ("4", "Music"), ("5", "Test Streams")]
CHANNELS = [
    dict(id=101, name="Neris News", cat="1", epg="neris.news", short="NN", hue=0.58, kind="h264", archive=3,
         shows=["Morning Briefing", "World Today", "Market Watch", "Evening News", "Weather Hour", "Late Edition"]),
    dict(id=102, name="Amber Business", cat="1", epg="amber.business", short="AB", hue=0.10, kind="h264", archive=0,
         shows=["Opening Bell", "Small Business Hour", "Crypto Corner", "Closing Bell", "The Interview"]),
    dict(id=201, name="Dune Sports HD", cat="2", epg="dune.sports", short="DS", hue=0.33, kind="hevc", archive=0,
         shows=["Match Day Live", "Goals Extra", "Tennis Highlights", "Basketball Tonight", "Sports Desk"]),
    dict(id=202, name="Lagoon Sports SD", cat="2", epg="lagoon.sports", short="LS", hue=0.47, kind="interlaced", archive=2,
         shows=["Classic Matches", "Rally Review", "Cycling Stage", "Boxing Nights"]),
    dict(id=301, name="Pine Kids", cat="3", epg="pine.kids", short="PK", hue=0.28, kind="h264", archive=1,
         shows=["Tiny Robots", "Forest Friends", "Sing Along", "Story Time", "Draw With Me"]),
    dict(id=401, name="Echo Music", cat="4", epg="echo.music", short="EM", hue=0.83, kind="ac3", archive=0,
         shows=["Top 20", "Acoustic Session", "Night Mix", "Retro Hits", "Live Lounge"]),
    dict(id=501, name="Broken Stream", cat="5", epg="broken.stream", short="!!", hue=0.0, kind="broken", archive=0,
         shows=["Nothing Works Here"]),
]

VOD_CATEGORIES = [("10", "Action"), ("11", "Comedy"), ("12", "Documentary"), ("13", "Test Formats")]
MOVIES = [
    dict(id=1001, name="The Last Lighthouse", year=2021, cat="10", genre="Action, Thriller", rating=7.4, hue=0.60, kind="mp4",
         plot="A retired keeper returns to the coast when the last working lighthouse goes dark."),
    dict(id=1002, name="Copper Sky", year=2019, cat="10", genre="Action, Sci-Fi", rating=6.8, hue=0.07, kind="mp4",
         plot="Two pilots race a dust storm across a mining planet."),
    dict(id=1003, name="Grandma's Robot", year=2022, cat="11", genre="Comedy, Family", rating=7.9, hue=0.15, kind="mp4",
         plot="A grandmother teaches her new care robot to cheat at cards."),
    dict(id=1004, name="Too Many Cats", year=2018, cat="11", genre="Comedy", rating=6.1, hue=0.95, kind="mp4",
         plot="A man inherits a flat, and the forty cats that come with it."),
    dict(id=1005, name="Rivers of Amber", year=2020, cat="12", genre="Documentary, Nature", rating=8.2, hue=0.11, kind="mp4",
         plot="A year along the Baltic coast, from storms to amber hunters."),
    dict(id=1006, name="Night Trains", year=2023, cat="12", genre="Documentary, Travel", rating=7.7, hue=0.68, kind="mp4",
         plot="The last sleeper trains of Europe and the people who run them."),
    dict(id=1007, name="Two Languages", year=2024, cat="13", genre="Test", rating=5.0, hue=0.40, kind="mkv",
         plot="MKV with English and Lithuanian audio tracks and subtitles, for trying track selection."),
    dict(id=1008, name="Ultra Clear (HEVC)", year=2024, cat="13", genre="Test", rating=5.0, hue=0.52, kind="hevc",
         plot="1080p HEVC in MP4."),
]

SERIES_CATEGORIES = [("20", "Drama"), ("21", "Animation")]
SERIES = [
    dict(id=2001, name="Harbor Lights", year=2022, cat="20", genre="Drama", rating=8.1, hue=0.56,
         plot="A fishing town keeps its secrets through two hard winters.",
         seasons={1: ["Pilot", "Low Tide", "The Storm"], 2: ["Return", "Fog", "Lanterns"]}),
    dict(id=2002, name="Night Shift Diaries", year=2023, cat="20", genre="Drama, Medical", rating=7.3, hue=0.72,
         plot="Three nurses, one hospital, every night from ten to six.",
         seasons={1: ["First Night", "Code Blue", "Sunrise"]}),
    dict(id=2003, name="Tiny Robots", year=2021, cat="21", genre="Animation, Kids", rating=8.6, hue=0.30,
         plot="Small robots, big adventures in a kitchen drawer.",
         seasons={1: ["Hello, World", "Bolt Goes Missing", "Rust Party", "The Big Recharge"]}),
]

def episodes(series):
    for season, titles in series["seasons"].items():
        for number, title in enumerate(titles, 1):
            yield dict(id=f"{series['id']}{season:02}{number:02}", season=season, number=number, title=title, series=series)

def all_episodes():
    return [e for s in SERIES for e in episodes(s)]

def add_extra_channels(count):
    sources = [c for c in CHANNELS if c["kind"] == "h264"]
    if count:
        LIVE_CATEGORIES.append(("6", "Filler"))
    for i in range(count):
        source = sources[i % len(sources)]
        CHANNELS.append(dict(id=10000 + i, name=f"Filler {i + 1:05}", cat="6", epg=f"filler.{i + 1}", short="F",
                             hue=source["hue"], kind="h264", archive=0, shows=source["shows"], loop=source["id"]))

# MARK: - Media

CARD_SWIFT = r'''
import AppKit
struct Job: Decodable { let out: String; let w: Int; let h: Int; let style: String; let title: String; let subtitle: String?; let hue: Double }
let jobs = try! JSONDecoder().decode([Job].self, from: FileManager.default.contents(atPath: CommandLine.arguments[1])!)
func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, in rect: NSRect, alpha: CGFloat = 1) {
    let style = NSMutableParagraphStyle(); style.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color.withAlphaComponent(alpha), .paragraphStyle: style]
    let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
    let bounds = (s as NSString).boundingRect(with: rect.size, options: options, attributes: attrs)
    let y = rect.minY + (rect.height - min(bounds.height, rect.height)) / 2
    (s as NSString).draw(with: NSRect(x: rect.minX, y: y, width: rect.width, height: min(bounds.height, rect.height)), options: options, attributes: attrs)
}
for job in jobs {
    let w = CGFloat(job.w), h = CGFloat(job.h)
    let ctx = CGContext(data: nil, width: job.w, height: job.h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let light = NSColor(hue: job.hue, saturation: 0.55, brightness: 0.70, alpha: 1)
    let dark = NSColor(hue: job.hue, saturation: 0.75, brightness: 0.16, alpha: 1)
    let full = NSRect(x: 0, y: 0, width: w, height: h)
    switch job.style {
    case "overlay":
        let panel = NSRect(x: w * 0.06, y: h * 0.07, width: w * 0.88, height: h * 0.25)
        NSColor(white: 0, alpha: 0.62).setFill()
        NSBezierPath(roundedRect: panel, xRadius: h * 0.03, yRadius: h * 0.03).fill()
        text(job.title, h * 0.075, .bold, .white, in: NSRect(x: panel.minX, y: panel.midY, width: panel.width, height: panel.height / 2))
        text(job.subtitle ?? "", h * 0.045, .medium, .white, in: NSRect(x: panel.minX, y: panel.minY + h * 0.02, width: panel.width, height: panel.height / 2 - h * 0.02), alpha: 0.8)
    case "logo":
        NSGradient(starting: light, ending: dark)!.draw(in: NSBezierPath(roundedRect: full, xRadius: w * 0.22, yRadius: h * 0.22), angle: -60)
        text(job.title, h * 0.40, .heavy, .white, in: full.insetBy(dx: w * 0.06, dy: h * 0.06))
    default: // poster, backdrop, still
        NSGradient(starting: light, ending: dark)!.draw(in: full, angle: -70)
        NSColor(white: 1, alpha: 0.07).setFill()
        NSBezierPath(ovalIn: NSRect(x: w * 0.45, y: h * 0.45, width: max(w, h) * 0.9, height: max(w, h) * 0.9)).fill()
        let titleSize = job.style == "poster" ? w * 0.12 : h * 0.10
        text(job.title, titleSize, .bold, .white, in: NSRect(x: w * 0.08, y: h * 0.35, width: w * 0.84, height: h * 0.40))
        text(job.subtitle ?? "", titleSize * 0.45, .medium, .white, in: NSRect(x: w * 0.08, y: h * 0.10, width: w * 0.84, height: h * 0.18), alpha: 0.8)
    }
    NSGraphicsContext.restoreGraphicsState()
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: job.out) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}
'''

def path(*parts):
    return os.path.join(CACHE, *parts)

def run(cmd):
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"Failed: {' '.join(cmd)}\n{result.stderr[-3000:]}")

def render_cards(jobs):
    jobs = [j for j in jobs if not os.path.exists(j["out"])]
    if not jobs:
        return
    tool = path("cardmaker")
    digest = hashlib.sha256(CARD_SWIFT.encode()).hexdigest()[:12]
    if not os.path.exists(f"{tool}-{digest}"):
        with open(path("cardmaker.swift"), "w") as f:
            f.write(CARD_SWIFT)
        print("Compiling the title card helper…")
        run(["xcrun", "swiftc", "-O", path("cardmaker.swift"), "-o", f"{tool}-{digest}"])
    with open(path("cards.json"), "w") as f:
        json.dump(jobs, f)
    print(f"Rendering {len(jobs)} images…")
    run([f"{tool}-{digest}", path("cards.json")])

def has_encoder(name):
    out = subprocess.run(["ffmpeg", "-hide_banner", "-encoders"], capture_output=True, text=True).stdout
    return f" {name} " in out

def encode(out, seconds, w, h, overlay, video, audio, rate=25, extra_inputs=(), maps=None, fmt=None, tone=440):
    """Test pattern with a title card on top and a beeping tone, encoded with the given codec arguments."""
    if os.path.exists(out):
        return
    tmp = out + ".part" + os.path.splitext(out)[1]
    source_rate = rate * 2 if "interlaced" in video else rate
    chain = f"[0:v][1:v]overlay=0:0,format=yuv420p"
    if "interlaced" in video:
        chain += ",tinterlace=mode=interleave_top,setfield=tff"
    cmd = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
           "-f", "lavfi", "-i", f"testsrc=size={w}x{h}:rate={source_rate}:duration={seconds}",
           "-i", overlay,
           "-f", "lavfi", "-i", f"sine=frequency={tone}:beep_factor=4:sample_rate=48000:duration={seconds}"]
    for extra in extra_inputs:
        cmd += extra
    cmd += ["-filter_complex", f"{chain}[v];[2:a]volume=0.3[a]"]
    cmd += maps or ["-map", "[v]", "-map", "[a]"]
    cmd += [a for a in video if a != "interlaced"] + audio
    if fmt:
        cmd += fmt
    cmd += [tmp]
    run(cmd)
    os.rename(tmp, out)

H264 = ["-c:v", "libx264", "-preset", "veryfast", "-profile:v", "high", "-b:v", "2500k", "-maxrate", "3000k", "-bufsize", "6000k"]
AAC = ["-c:a", "aac", "-b:a", "128k", "-ac", "2"]

def hevc_args():
    if has_encoder("hevc_videotoolbox"):
        return ["-c:v", "hevc_videotoolbox", "-b:v", "5000k", "-tag:v", "hvc1"]
    return ["-c:v", "libx265", "-preset", "ultrafast", "-b:v", "5000k", "-tag:v", "hvc1"]

def live_job(channel):
    folder = path("live", str(channel["id"]))
    if os.path.exists(os.path.join(folder, "index.m3u8")):
        return
    os.makedirs(folder, exist_ok=True)
    keys = ["-force_key_frames", f"expr:gte(t,n_forced*{SEGMENT})", "-sc_threshold", "0"]
    kind = channel["kind"]
    w, h, video, audio = 1280, 720, H264, AAC
    if kind == "hevc":
        w, h, video = 1920, 1080, hevc_args()
        video = [a for a in video if a not in ("-tag:v", "hvc1")]
    elif kind == "interlaced":
        w, h = 720, 576
        video = ["interlaced", "-c:v", "libx264", "-preset", "veryfast", "-b:v", "2000k",
                 "-x264-params", "interlaced=1:tff=1", "-aspect", "16:9"]
        audio = ["-c:a", "mp2", "-b:a", "192k", "-ac", "2"]
    elif kind == "ac3":
        audio = ["-c:a", "ac3", "-b:a", "192k", "-ac", "2"]
    overlay = path("cards", f"live-{channel['id']}-{w}x{h}.png")
    tmp = folder + ".part"
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    encode(os.path.join(tmp, "index.m3u8"), LIVE_LOOP, w, h, overlay, video + keys, audio,
           tone=300 + channel["id"] % 7 * 60,
           fmt=["-f", "hls", "-hls_time", str(SEGMENT), "-hls_playlist_type", "vod",
                "-hls_segment_filename", os.path.join(tmp, "%03d.ts")])
    shutil.rmtree(folder)
    os.rename(tmp, folder)

def movie_job(movie):
    out = path("vod", f"movie-{movie['id']}.{movie_extension(movie)}")
    if movie["kind"] == "hevc":
        encode(out, MOVIE_LENGTH, 1920, 1080, path("cards", f"movie-{movie['id']}-1920x1080.png"), hevc_args(), AAC,
               fmt=["-movflags", "+faststart"])
    elif movie["kind"] == "mkv":
        subs = []
        for lang, text in (("eng", "English subtitle"), ("lit", "Lietuviški subtitrai")):
            srt = path("vod", f"subs-{lang}.srt")
            with open(srt, "w") as f:
                for i in range(MOVIE_LENGTH // 5):
                    f.write(f"{i + 1}\n00:{i * 5 // 60:02}:{i * 5 % 60:02},500 --> 00:{(i * 5 + 4) // 60:02}:{(i * 5 + 4) % 60:02},500\n{text} {i + 1}\n\n")
            subs.append(srt)
        extra = [["-f", "lavfi", "-i", f"sine=frequency=660:beep_factor=2:sample_rate=48000:duration={MOVIE_LENGTH}"],
                 ["-i", subs[0]], ["-i", subs[1]]]
        encode(out, MOVIE_LENGTH, 1280, 720, path("cards", f"movie-{movie['id']}-1280x720.png"), H264,
               AAC + ["-c:s", "srt",
                      "-metadata:s:a:0", "language=eng", "-metadata:s:a:0", "title=English",
                      "-metadata:s:a:1", "language=lit", "-metadata:s:a:1", "title=Lietuvių",
                      "-metadata:s:s:0", "language=eng", "-metadata:s:s:1", "language=lit"],
               extra_inputs=extra,
               maps=["-map", "[v]", "-map", "[a]", "-map", "3:a", "-map", "4:s", "-map", "5:s"])
    else:
        encode(out, MOVIE_LENGTH, 1280, 720, path("cards", f"movie-{movie['id']}-1280x720.png"), H264, AAC,
               tone=400 + movie["id"] % 9 * 40, fmt=["-movflags", "+faststart"])

def episode_job(episode):
    encode(path("vod", f"episode-{episode['id']}.mp4"), EPISODE_LENGTH, 1280, 720,
           path("cards", f"episode-{episode['id']}-1280x720.png"), H264, AAC,
           tone=350 + episode["number"] * 50, fmt=["-movflags", "+faststart"])

def movie_extension(movie):
    return "mkv" if movie["kind"] == "mkv" else "mp4"

def prepare_media():
    if not shutil.which("ffmpeg"):
        sys.exit("ffmpeg isn't installed (brew install ffmpeg).")
    for folder in ("cards", "img", "live", "vod"):
        os.makedirs(path(folder), exist_ok=True)
    cards = []
    def card(out, w, h, style, title, subtitle, hue):
        cards.append(dict(out=path(*out), w=w, h=h, style=style, title=title, subtitle=subtitle, hue=hue))
    for c in CHANNELS:
        card(("img", f"logo-{c['id']}.png"), 256, 256, "logo", c["short"], None, c["hue"])
        if c["kind"] == "broken" or "loop" in c:
            continue
        size = {"hevc": (1920, 1080), "interlaced": (720, 576)}.get(c["kind"], (1280, 720))
        card(("cards", f"live-{c['id']}-{size[0]}x{size[1]}.png"), *size, "overlay", c["name"],
             f"LIVE · {c['kind'].upper()} · {size[1]}{'i' if c['kind'] == 'interlaced' else 'p'}", c["hue"])
    for m in MOVIES:
        sub = f"{m['year']} · {m['genre']}"
        card(("img", f"poster-{m['id']}.png"), 400, 600, "poster", m["name"], sub, m["hue"])
        card(("img", f"backdrop-{m['id']}.png"), 1280, 720, "backdrop", m["name"], sub, m["hue"])
        size = (1920, 1080) if m["kind"] == "hevc" else (1280, 720)
        card(("cards", f"movie-{m['id']}-{size[0]}x{size[1]}.png"), *size, "overlay", m["name"], f"Movie · {m['year']}", m["hue"])
    for s in SERIES:
        card(("img", f"poster-{s['id']}.png"), 400, 600, "poster", s["name"], f"{s['year']} · {s['genre']}", s["hue"])
        card(("img", f"backdrop-{s['id']}.png"), 1280, 720, "backdrop", s["name"], s["genre"], s["hue"])
    for e in all_episodes():
        code = f"S{e['season']:02}E{e['number']:02}"
        card(("img", f"still-{e['id']}.png"), 640, 360, "still", e["title"], f"{e['series']['name']} · {code}", e["series"]["hue"])
        card(("cards", f"episode-{e['id']}-1280x720.png"), 1280, 720, "overlay", f"{e['series']['name']} {code}",
             e["title"], e["series"]["hue"])
    render_cards(cards)

    jobs = [lambda c=c: live_job(c) for c in CHANNELS if c["kind"] != "broken" and "loop" not in c]
    jobs += [lambda m=m: movie_job(m) for m in MOVIES]
    jobs += [lambda e=e: episode_job(e) for e in all_episodes()]
    print("Encoding video (only missing files; the first run takes a few minutes)…")
    with ThreadPoolExecutor(max_workers=3) as pool:
        for future in [pool.submit(job) for job in jobs]:
            future.result()
    for c in CHANNELS:
        if c["kind"] != "broken" and "loop" not in c:
            c["segments"] = sorted(f for f in os.listdir(path("live", str(c["id"]))) if f.endswith(".ts"))
    for c in CHANNELS:
        if "loop" in c:
            c["segments"] = next(o["segments"] for o in CHANNELS if o["id"] == c["loop"])

# MARK: - Guide

def schedule(channel, start, end):
    """Programmes covering start...end, the same on every request: each UTC day restarts the channel's rotation."""
    lengths = [30, 60, 45, 90, 60, 30]
    day = datetime.fromtimestamp(start, timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
    offset = channel["id"] % 4
    while day.timestamp() < end:
        t, i = int(day.timestamp()), 0
        day_end = t + 86400
        while t < day_end:
            length = min(lengths[(i + offset) % len(lengths)] * 60, day_end - t)
            if t + length > start and t < end:
                title = channel["shows"][(i + offset) % len(channel["shows"])]
                yield t, t + length, title, f"{title} on {channel['name']}, {datetime.fromtimestamp(t, timezone.utc):%A %H:%M} UTC."
            t += length
            i += 1
        day += timedelta(days=1)

def xmltv(base, creds):
    now = int(time.time())
    def stamp(t): return datetime.fromtimestamp(t, timezone.utc).strftime("%Y%m%d%H%M%S +0000")
    lines = ['<?xml version="1.0" encoding="UTF-8"?>', '<tv generator-info-name="RpTv mock Xtream">']
    for c in CHANNELS:
        lines.append(f'<channel id="{c["epg"]}"><display-name>{escape(c["name"])}</display-name>'
                     f'<icon src="{base}/img/logo-{c["id"]}.png"/></channel>')
    for c in CHANNELS:
        for start, stop, title, desc in schedule(c, now - 3 * 86400, now + 2 * 86400):
            lines.append(f'<programme start="{stamp(start)}" stop="{stamp(stop)}" channel="{c["epg"]}">'
                         f'<title lang="en">{escape(title)}</title><desc lang="en">{escape(desc)}</desc></programme>')
    lines.append("</tv>")
    return "\n".join(lines).encode()

# MARK: - API

def account(base, username, status):
    host = urlparse(base)
    now = int(time.time())
    return {
        "user_info": {"username": username, "password": USERS[username][0], "message": "RpTv mock server", "auth": 1,
                      "status": status, "exp_date": str(now + (30 if status == "Active" else -3) * 86400),
                      "is_trial": "0", "active_cons": "0", "created_at": str(now - 365 * 86400), "max_connections": "2",
                      "allowed_output_formats": ["m3u8", "ts"]},
        "server_info": {"url": host.hostname, "port": str(host.port or 80), "https_port": "443", "server_protocol": "http",
                        "rtmp_port": "1935", "timezone": SERVER_TZ, "timestamp_now": now,
                        "time_now": datetime.now().strftime("%Y-%m-%d %H:%M:%S")},
    }

def categories(items):
    return [{"category_id": cid, "category_name": name, "parent_id": 0} for cid, name in items]

def live_streams(base):
    return [{"num": i + 1, "name": c["name"], "stream_type": "live", "stream_id": c["id"],
             "stream_icon": f"{base}/img/logo-{c['id']}.png", "epg_channel_id": c["epg"], "added": str(STARTED),
             "category_id": c["cat"], "category_ids": [int(c["cat"])], "custom_sid": "", "direct_source": "",
             "tv_archive": 1 if c["archive"] else 0, "tv_archive_duration": c["archive"]}
            for i, c in enumerate(CHANNELS)]

def vod_streams(base):
    return [{"num": i + 1, "name": m["name"], "stream_type": "movie", "stream_id": m["id"],
             "stream_icon": f"{base}/img/poster-{m['id']}.png", "rating": str(m["rating"]), "rating_5based": m["rating"] / 2,
             "added": str(STARTED - i * 86400), "category_id": m["cat"], "container_extension": movie_extension(m),
             "custom_sid": "", "direct_source": "", "year": str(m["year"])}
            for i, m in enumerate(MOVIES)]

def vod_info(base, movie_id):
    m = next((m for m in MOVIES if m["id"] == movie_id), None)
    if not m:
        return {"info": [], "movie_data": []}
    return {"info": {"name": m["name"], "o_name": m["name"], "movie_image": f"{base}/img/poster-{m['id']}.png",
                     "cover_big": f"{base}/img/poster-{m['id']}.png", "backdrop_path": [f"{base}/img/backdrop-{m['id']}.png"],
                     "plot": m["plot"], "description": m["plot"], "genre": m["genre"], "director": "A. Director",
                     "cast": "Actor One, Actor Two, Actor Three", "releasedate": f"{m['year']}-05-01",
                     "duration_secs": MOVIE_LENGTH, "duration": f"00:{MOVIE_LENGTH // 60:02}:00", "rating": str(m["rating"]),
                     "tmdb_id": "", "youtube_trailer": ""},
            "movie_data": {"stream_id": m["id"], "name": m["name"], "added": str(STARTED), "category_id": m["cat"],
                           "container_extension": movie_extension(m), "custom_sid": "", "direct_source": ""}}

def series_list(base):
    return [{"num": i + 1, "name": s["name"], "series_id": s["id"], "cover": f"{base}/img/poster-{s['id']}.png",
             "plot": s["plot"], "cast": "Actor One, Actor Two", "director": "B. Director", "genre": s["genre"],
             "releaseDate": f"{s['year']}-09-01", "last_modified": str(STARTED), "rating": str(s["rating"]),
             "rating_5based": s["rating"] / 2, "backdrop_path": [f"{base}/img/backdrop-{s['id']}.png"],
             "youtube_trailer": "", "episode_run_time": str(EPISODE_LENGTH // 60), "category_id": s["cat"],
             "category_ids": [int(s["cat"])]}
            for i, s in enumerate(SERIES)]

def series_info(base, series_id):
    s = next((s for s in SERIES if s["id"] == series_id), None)
    if not s:
        return {"seasons": [], "info": [], "episodes": []}
    by_season = {}
    for e in episodes(s):
        by_season.setdefault(str(e["season"]), []).append({
            "id": e["id"], "episode_num": e["number"], "title": f"{s['name']} - S{e['season']:02}E{e['number']:02} - {e['title']}",
            "container_extension": "mp4", "season": e["season"], "added": str(STARTED), "custom_sid": "", "direct_source": "",
            "info": {"plot": f"{e['title']}: episode {e['number']} of season {e['season']}.", "duration_secs": EPISODE_LENGTH,
                     "duration": f"00:{EPISODE_LENGTH // 60:02}:00", "movie_image": f"{base}/img/still-{e['id']}.png",
                     "rating": str(s["rating"]), "releasedate": f"{s['year'] + e['season'] - 1}-09-{e['number']:02}"}})
    return {"seasons": [{"season_number": n, "name": f"Season {n}", "episode_count": len(t),
                         "cover": f"{base}/img/poster-{s['id']}.png", "cover_big": f"{base}/img/poster-{s['id']}.png",
                         "air_date": f"{s['year'] + n - 1}-09-01", "overview": ""} for n, t in s["seasons"].items()],
            "info": {"name": s["name"], "cover": f"{base}/img/poster-{s['id']}.png", "plot": s["plot"], "genre": s["genre"],
                     "cast": "Actor One, Actor Two", "director": "B. Director", "releaseDate": f"{s['year']}-09-01",
                     "rating": str(s["rating"]), "backdrop_path": [f"{base}/img/backdrop-{s['id']}.png"],
                     "youtube_trailer": "", "episode_run_time": str(EPISODE_LENGTH // 60), "category_id": s["cat"]},
            "episodes": by_season}

def short_epg(stream_id, limit):
    c = next((c for c in CHANNELS if c["id"] == stream_id), None)
    if not c:
        return {"epg_listings": []}
    now = int(time.time())
    listings = []
    for start, stop, title, desc in schedule(c, now, now + 2 * 86400):
        listings.append({"id": str(start), "epg_id": c["epg"], "title": base64.b64encode(title.encode()).decode(),
                         "lang": "en", "start": datetime.fromtimestamp(start).strftime("%Y-%m-%d %H:%M:%S"),
                         "end": datetime.fromtimestamp(stop).strftime("%Y-%m-%d %H:%M:%S"),
                         "description": base64.b64encode(desc.encode()).decode(), "channel_id": c["epg"],
                         "start_timestamp": str(start), "stop_timestamp": str(stop)})
        if len(listings) >= limit:
            break
    return {"epg_listings": listings}

def m3u(base, user, password, output):
    ext = "m3u8" if output in ("m3u8", "hls") else "ts"
    lines = [f'#EXTM3U url-tvg="{base}/xmltv.php?username={user}&password={password}"']
    names = dict(LIVE_CATEGORIES)
    for c in CHANNELS:
        catchup = f' catchup="shift" catchup-days="{c["archive"]}"' if c["archive"] else ""
        lines.append(f'#EXTINF:-1 tvg-id="{c["epg"]}" tvg-name="{c["name"]}" tvg-logo="{base}/img/logo-{c["id"]}.png" '
                     f'group-title="{names[c["cat"]]}"{catchup},{c["name"]}')
        lines.append(f"{base}/live/{user}/{password}/{c['id']}.{ext}")
    names = dict(VOD_CATEGORIES)
    for m in MOVIES:
        lines.append(f'#EXTINF:-1 tvg-logo="{base}/img/poster-{m["id"]}.png" group-title="{names[m["cat"]]}",{m["name"]} ({m["year"]})')
        lines.append(f"{base}/movie/{user}/{password}/{m['id']}.{movie_extension(m)}")
    names = dict(SERIES_CATEGORIES)
    for e in all_episodes():
        s = e["series"]
        lines.append(f'#EXTINF:-1 tvg-logo="{base}/img/still-{e["id"]}.png" group-title="{names[s["cat"]]}",'
                     f'{s["name"]} S{e["season"]:02}E{e["number"]:02}')
        lines.append(f"{base}/series/{user}/{password}/{e['id']}.mp4")
    return ("\n".join(lines) + "\n").encode()

# MARK: - Live

def live_playlist(channel):
    count = len(channel["segments"])
    current = int(time.time()) // SEGMENT   # the segment being "recorded" now; the ones before it are complete
    first = current - 6
    lines = ["#EXTM3U", "#EXT-X-VERSION:3", f"#EXT-X-TARGETDURATION:{SEGMENT}", f"#EXT-X-MEDIA-SEQUENCE:{first}",
             f"#EXT-X-DISCONTINUITY-SEQUENCE:{first // count}"]
    for seq in range(first, current):
        if seq % count == 0 and seq != first:
            lines.append("#EXT-X-DISCONTINUITY")
        lines += [f"#EXTINF:{SEGMENT}.000,", f"/hls/{channel['id']}/{seq}.ts"]
    return ("\n".join(lines) + "\n").encode()

def segment_file(channel, seq):
    source = channel.get("loop", channel["id"])
    return path("live", str(source), channel["segments"][seq % len(channel["segments"])])

# MARK: - Server

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "RpTvMockXtream/1.0"

    def log_message(self, fmt, *args):
        if not self.path.startswith(("/hls/", "/img/")):
            sys.stderr.write(f"{datetime.now():%H:%M:%S} {self.address_string()} {fmt % args}\n")

    @property
    def base(self):
        return f"http://{self.headers.get('Host') or 'localhost'}"

    def send(self, status, body=b"", content_type="text/plain", headers=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def json(self, value):
        self.send(200, json.dumps(value).encode(), "application/json")

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        try:
            self.route()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def authorized(self, user, password):
        return user in USERS and USERS[user][0] == password

    def route(self):
        url = urlparse(self.path)
        query = {k: v[0] for k, v in parse_qs(url.query).items()}
        parts = [p for p in url.path.split("/") if p]
        if url.path.endswith(("/player_api.php", "/xmltv.php", "/get.php")):
            user, password = query.get("username", ""), query.get("password", "")
            if not self.authorized(user, password):
                if url.path.endswith("player_api.php"):
                    return self.json({"user_info": {"auth": 0}})
                return self.send(401, b"Unauthorized")
            if url.path.endswith("xmltv.php"):
                return self.send(200, xmltv(self.base, (user, password)), "application/xml")
            if url.path.endswith("get.php"):
                return self.send(200, m3u(self.base, user, password, query.get("output", "ts")), "audio/x-mpegurl")
            return self.api(user, query)
        if parts[:1] == ["img"] and len(parts) == 2:
            return self.file(path("img", os.path.basename(parts[1])), "image/png")
        if parts[:1] == ["hls"] and len(parts) == 3:
            channel = self.channel(parts[1])
            seq = re.match(r"(\d+)\.ts$", parts[2])
            if not channel or not seq or "segments" not in channel:
                return self.send(404, b"Not found")
            return self.file(segment_file(channel, int(seq.group(1))), "video/mp2t")
        if parts[:1] in (["live"], ["movie"], ["series"], ["timeshift"]) and len(parts) >= 4:
            if not self.authorized(parts[1], parts[2]):
                return self.send(403, b"Forbidden")
            name, _, ext = parts[-1].partition(".")
            if parts[0] == "movie":
                m = next((m for m in MOVIES if str(m["id"]) == name), None)
                return self.file(path("vod", f"movie-{name}.{movie_extension(m)}") if m else "", self.video_type(ext))
            if parts[0] == "series":
                return self.file(path("vod", f"episode-{os.path.basename(name)}.mp4"), "video/mp4")
            channel = self.channel(name)
            if not channel or channel["kind"] == "broken":
                return self.send(404, b"Not found")
            if parts[0] == "timeshift" or "utc" in query:
                print(f"    catch-up of {channel['name']}: {'/'.join(parts[3:5]) if parts[0] == 'timeshift' else query}")
                return self.archive(channel)
            if ext == "m3u8":
                return self.send(200, live_playlist(channel), "application/vnd.apple.mpegurl", {"Cache-Control": "no-cache"})
            return self.live_ts(channel)
        self.send(404, b"Not found")

    def api(self, user, query):
        base = self.base
        action = query.get("action")
        if action is None:
            return self.json(account(base, user, USERS[user][1]))
        if USERS[user][1] != "Active":
            return self.json([])
        number = lambda key: int(query.get(key, "0")) if query.get(key, "0").isdigit() else 0
        handlers = {
            "get_live_categories": lambda: categories(LIVE_CATEGORIES),
            "get_live_streams": lambda: [s for s in live_streams(base) if query.get("category_id") in (None, s["category_id"])],
            "get_vod_categories": lambda: categories(VOD_CATEGORIES),
            "get_vod_streams": lambda: [s for s in vod_streams(base) if query.get("category_id") in (None, s["category_id"])],
            "get_vod_info": lambda: vod_info(base, number("vod_id")),
            "get_series_categories": lambda: categories(SERIES_CATEGORIES),
            "get_series": lambda: [s for s in series_list(base) if query.get("category_id") in (None, s["category_id"])],
            "get_series_info": lambda: series_info(base, number("series_id")),
            "get_short_epg": lambda: short_epg(number("stream_id"), number("limit") or 4),
            "get_simple_data_table": lambda: short_epg(number("stream_id"), 1000),
        }
        self.json(handlers[action]() if action in handlers else [])

    def channel(self, name):
        return next((c for c in CHANNELS if str(c["id"]) == name), None)

    @staticmethod
    def video_type(ext):
        return {"mp4": "video/mp4", "mkv": "video/x-matroska", "ts": "video/mp2t"}.get(ext, "application/octet-stream")

    def file(self, file_path, content_type):
        """A file with byte-range support, which AVPlayer needs to seek."""
        if not file_path or not os.path.isfile(file_path):
            return self.send(404, b"Not found")
        size = os.path.getsize(file_path)
        start, end = 0, size - 1
        match = re.match(r"bytes=(\d*)-(\d*)", self.headers.get("Range", ""))
        if match and (match.group(1) or match.group(2)):
            if match.group(1):
                start = int(match.group(1))
                end = min(int(match.group(2)), size - 1) if match.group(2) else size - 1
            else:
                start = max(0, size - int(match.group(2)))
            if start >= size:
                return self.send(416, b"", headers={"Content-Range": f"bytes */{size}"})
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        else:
            self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        self.end_headers()
        if self.command == "HEAD":
            return
        with open(file_path, "rb") as f:
            f.seek(start)
            remaining = end - start + 1
            while remaining > 0:
                chunk = f.read(min(256 * 1024, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)

    def archive(self, channel):
        if channel.get("loop"):
            channel = self.channel(str(channel["loop"]))
        archive = path("live", str(channel["id"]), "archive.ts")
        if not os.path.exists(archive):
            with open(archive + ".part", "wb") as out:
                for segment in channel["segments"]:
                    with open(path("live", str(channel["id"]), segment), "rb") as f:
                        shutil.copyfileobj(f, out)
            os.replace(archive + ".part", archive)
        self.file(archive, "video/mp2t")

    def live_ts(self, channel):
        """An endless MPEG-TS stream: the last two segments at once, then each new one as its time comes."""
        self.send_response(200)
        self.send_header("Content-Type", "video/mp2t")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        if self.command == "HEAD":
            return
        seq = int(time.time()) // SEGMENT - 2
        while True:
            ready = (seq + 1) * SEGMENT
            if time.time() < ready:
                time.sleep(ready - time.time())
            with open(segment_file(channel, seq), "rb") as f:
                shutil.copyfileobj(f, self.wfile)
            self.wfile.flush()
            seq += 1

def lan_addresses():
    addresses = []
    for interface in ("en0", "en1"):
        out = subprocess.run(["ipconfig", "getifaddr", interface], capture_output=True, text=True).stdout.strip()
        if out:
            addresses.append(out)
    if not addresses:
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                s.connect(("10.255.255.255", 1))
                addresses.append(s.getsockname()[0])
        except OSError:
            addresses.append("127.0.0.1")
    return addresses

def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--extra-channels", type=int, default=0, help="filler channels to add, for big catalogs")
    args = parser.parse_args()
    add_extra_channels(args.extra_channels)
    prepare_media()
    server = ThreadingHTTPServer(("0.0.0.0", args.port), Handler)
    server.daemon_threads = True
    print("\nRpTv mock Xtream server is running. In the app, add an Xtream source with:")
    for address in lan_addresses():
        print(f"    Server:   http://{address}:{args.port}")
    print("    Username: demo\n    Password: demo")
    print(f"M3U playlist: http://{lan_addresses()[0]}:{args.port}/get.php?username=demo&password=demo&type=m3u_plus")
    print("The phone must be on the same Wi-Fi. Ctrl-C stops the server.\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass

if __name__ == "__main__":
    main()
