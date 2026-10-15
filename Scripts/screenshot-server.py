#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""A made-up Xtream Codes server for the App Store screenshots (UITests/ScreenshotUITests, run by
Scripts/screenshots.sh).

Movies and series are Blender Foundation open movies (CC BY), with posters and stills from
Support/screenshot-art (credits in its CREDITS.md). Channels and programmes are made up. Streams redirect to
public test streams of those films. Any username and password log in.

    Scripts/screenshot-server.py [PORT, default 8765]
"""
import json, os, sys, time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse
from xml.sax.saxutils import escape

port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
art_dir = os.path.join(root, "Support", "screenshot-art")
base = f"http://127.0.0.1:{port}"
BUNNY = "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8"
STEEL = "https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.ism/.m3u8"


def art(name):
    return f"{base}/art/{name}"


# id, name, category, logo, archive days, stream, programmes (title, minutes, description)
channels = [
    (1, "Open Cinema", "1", "open-cinema", 3, BUNNY, [
        ("Big Buck Bunny", 30, "A giant rabbit takes comic revenge on three bullying rodents."),
        ("Sintel", 30, "A young woman searches a harsh land for the baby dragon taken from her."),
        ("Tears of Steel", 30, "Scientists in a future Amsterdam try to save the world from robots."),
        ("Elephants Dream", 30, "Two men wander a vast machine and see very different worlds in it."),
        ("Cosmos Laundromat", 30, "A sheep on a desolate island meets a salesman with a strange offer."),
        ("Spring", 30, "A shepherd girl and her dog face ancient spirits."),
        ("Sprite Fright", 30, "Rowdy teenagers meet the forest's tiny mushroom sprites."),
        ("Charge", 30, "An old man tries to steal energy from a guarded facility."),
    ]),
    (2, "Orbit News 24", "2", "orbit-news", 3, STEEL, [
        ("Morning Briefing", 60, "The day's top stories, weather and travel."),
        ("World Report", 30, "News from around the globe."),
        ("Markets Today", 30, "Stocks, currencies and the companies behind them."),
        ("Newsroom", 60, "Live coverage and analysis."),
        ("Science Desk", 30, "Space, climate and the lab."),
        ("Evening News", 60, "The full picture of the day."),
    ]),
    (3, "Tideway Sport", "3", "tideway-sport", 0, BUNNY, [
        ("Match Day Live", 120, "Build-up, kick-off and every goal."),
        ("Sailing Weekly", 30, "Racing on open water."),
        ("Cycling: Mountain Stage", 90, "The climb that decides the race."),
        ("Goals of the Week", 30, "The best strikes from every league."),
    ]),
    (4, "Llama Kids", "4", "llama-kids", 0, BUNNY, [
        ("Caminandes: Llama Drama", 30, "Koro the llama wants to cross a road."),
        ("Puzzle Pals", 30, "Friends solve a new riddle every day."),
        ("Caminandes: Gran Dillama", 30, "Koro tries to reach the grass beyond the fence."),
        ("Story Time", 30, "Tales read aloud, with pictures."),
        ("Caminandes: Llamigos", 30, "Koro meets a penguin in the snow."),
        ("Little Explorers", 30, "Curious kids discover the outdoors."),
    ]),
    (5, "Lumen Documentary", "5", "lumen-docs", 0, STEEL, [
        ("Wild Coasts", 60, "Life where the land meets the sea."),
        ("Inside the Render Farm", 30, "How an animated film gets made, frame by frame."),
        ("Deep Ocean Light", 60, "Creatures that make their own light."),
        ("Cities After Dark", 60, "What happens when the city sleeps."),
    ]),
    (6, "Velvet Music", "6", "velvet-music", 0, BUNNY, [
        ("Studio Sessions", 60, "Live performances from the studio floor."),
        ("Top 20 Countdown", 60, "This week's most played."),
        ("Jazz After Dark", 90, "Late-night jazz, old and new."),
        ("Acoustic Mornings", 30, "Unplugged songs to start the day."),
    ]),
    (7, "Nimbus One", "1", "nimbus-one", 0, STEEL, [
        ("Quiz Night", 60, "Four teams, one trophy."),
        ("The Long Weekend", 30, "A comedy about a trip that goes wrong."),
        ("Home Rescue", 60, "Old houses brought back to life."),
        ("Late Show", 60, "Guests, music and conversation."),
    ]),
    (8, "Kitchen Table", "1", "kitchen-table", 0, BUNNY, [
        ("Five-Minute Breakfasts", 30, "Quick starts for busy mornings."),
        ("Bread Basics", 30, "Flour, water, salt and patience."),
        ("Market to Plate", 60, "Cooking with what's in season."),
        ("Dinner in 30", 30, "A full meal in half an hour."),
    ]),
]
live_categories = [("1", "Entertainment"), ("2", "News"), ("3", "Sports"), ("4", "Kids"), ("5", "Documentary"),
                   ("6", "Music")]

# id, name, year, genre, seconds, director, cast, plot, poster, still, stream
movies = [
    (101, "Big Buck Bunny", 2008, "Animation, Comedy", 596, "Sacha Goedegebure", None,
     "A giant, gentle rabbit's peaceful day in the meadow is spoiled by three bullying rodents, and he plans a "
     "comic revenge.", "big-buck-bunny", "big-buck-bunny", BUNNY),
    (102, "Sintel", 2010, "Animation, Fantasy", 888, "Colin Levy", "Halina Reijn, Thom Hoffman",
     "A lonely young woman searches a harsh land for the baby dragon she rescued and raised, after it is taken "
     "from her.", "sintel", "sintel", BUNNY),
    (103, "Tears of Steel", 2012, "Sci-Fi, Action", 734, "Ian Hubert", "Derek de Lint, Sergio Hasselbaink",
     "In a future Amsterdam overrun by robots, a group of scientists tries to save the world by reliving a "
     "painful breakup.", "tears-of-steel", "tears-of-steel", STEEL),
    (104, "Elephants Dream", 2006, "Animation, Sci-Fi", 654, "Bassam Kurdali", "Tygo Gernandt, Cas Jansen",
     "Two men, the old Proog and the young Emo, wander a vast and strange machine, and see in it very different "
     "worlds.", "elephants-dream", "elephants-dream", BUNNY),
    (105, "Cosmos Laundromat", 2015, "Animation, Fantasy", 730, "Mathieu Auvray", None,
     "On a desolate island, a weary sheep named Franck meets a mysterious salesman who offers him the gift of a "
     "lifetime.", "cosmos-laundromat", None, BUNNY),
    (106, "Spring", 2019, "Animation, Fantasy", 464, "Andy Goralczyk", None,
     "A shepherd girl and her dog face ancient spirits to keep the cycle of life going.", "spring", None, BUNNY),
    (107, "Sprite Fright", 2021, "Animation, Comedy", 629, "Matthew Luhn", None,
     "A group of rowdy teenagers on a trip to the forest meets a band of tiny mushroom sprites with a dark side.",
     "sprite-fright", None, BUNNY),
    (108, "Charge", 2022, "Animation, Action", 232, None, None,
     "In a bleak future, an old man breaks into a guarded facility to steal energy, and comes up against its "
     "robot.", "charge", None, BUNNY),
]

series_plot = ("Koro, a stubborn young llama in Patagonia, keeps getting into trouble in his search for greener "
               "grass.")
# episode id, number, title, seconds, plot, still, year
episodes = [
    ("1001", 1, "Llama Drama", 90, "Koro wants to cross a road, and the road has other ideas.", "caminandes-1", 2013),
    ("1002", 2, "Gran Dillama", 146, "The grass is always greener on the other side of the fence.", "caminandes-2",
     2013),
    ("1003", 3, "Llamigos", 150, "In the winter snow, Koro meets Oti, a pesky penguin with a taste for berries.",
     "caminandes-3", 2016),
]


def account():
    now = int(time.time())
    return {"user_info": {"username": "demo", "auth": 1, "status": "Active", "exp_date": str(now + 365 * 86400),
                          "is_trial": "0", "active_cons": "0", "max_connections": "1", "created_at": str(now),
                          "allowed_output_formats": ["m3u8", "ts"]},
            "server_info": {"url": "127.0.0.1", "port": str(port), "server_protocol": "http", "timezone": "UTC",
                            "timestamp_now": now}}


def movie_stream(m):
    return {"num": m[0] - 100, "name": m[1], "stream_type": "movie", "stream_id": m[0],
            "stream_icon": art(f"poster-{m[8]}.jpg"), "year": m[2], "added": "1700000000", "category_id": "10",
            "container_extension": "m3u8"}


def movie_info(m):
    info = {"name": m[1], "cover_big": art(f"poster-{m[8]}.jpg"), "releasedate": f"{m[2]}-01-01",
            "genre": m[3], "duration_secs": m[4], "plot": m[7]}
    if m[5]: info["director"] = m[5]
    if m[6]: info["cast"] = m[6]
    if m[9]: info["backdrop_path"] = [art(f"still-{m[9]}.jpg")]
    return {"info": info, "movie_data": movie_stream(m)}


def series_entry():
    return {"num": 1, "name": "Caminandes", "series_id": 201, "cover": art("poster-caminandes.jpg"),
            "plot": series_plot, "director": "Pablo Vazquez", "genre": "Animation, Comedy", "releaseDate": "2013",
            "last_modified": "1700000000", "backdrop_path": [art("still-caminandes-2.jpg")], "category_id": "20"}


def series_info():
    return {"info": {"name": "Caminandes", "cover": art("poster-caminandes.jpg"), "plot": series_plot,
                     "director": "Pablo Vazquez", "genre": "Animation, Comedy", "releasedate": "2013",
                     "backdrop_path": [art("still-caminandes-2.jpg")]},
            "seasons": [{"season_number": 1, "name": "Season 1", "episode_count": len(episodes),
                         "cover": art("poster-caminandes.jpg")}],
            "episodes": {"1": [{"id": e[0], "episode_num": e[1], "title": e[2], "container_extension": "m3u8",
                                "season": 1, "info": {"plot": e[4], "duration_secs": e[3],
                                                      "movie_image": art(f"still-{e[5]}.jpg"),
                                                      "releasedate": f"{e[6]}-01-01"}} for e in episodes]}}


def api(query):
    action = query.get("action", [None])[0]
    if action is None: return account()
    if action == "get_live_categories":
        return [{"category_id": i, "category_name": n, "parent_id": 0} for i, n in live_categories]
    if action == "get_live_streams":
        return [{"num": c[0], "name": c[1], "stream_type": "live", "stream_id": c[0],
                 "stream_icon": art(f"logo-{c[3]}.png"), "epg_channel_id": f"{c[3]}.demo", "added": "1700000000",
                 "category_id": c[2], "tv_archive": 1 if c[4] else 0, "tv_archive_duration": c[4]} for c in channels]
    if action == "get_vod_categories": return [{"category_id": "10", "category_name": "Open Movies", "parent_id": 0}]
    if action == "get_vod_streams": return [movie_stream(m) for m in movies]
    if action == "get_vod_info":
        vod_id = int(query.get("vod_id", ["0"])[0])
        return next((movie_info(m) for m in movies if m[0] == vod_id), {"info": [], "movie_data": {}})
    if action == "get_series_categories":
        return [{"category_id": "20", "category_name": "Animation", "parent_id": 0}]
    if action == "get_series": return [series_entry()]
    if action == "get_series_info": return series_info()
    return []


def guide():
    hour = 3600
    start = (int(time.time()) // hour) * hour - 24 * hour
    end = start + 48 * hour
    ts = lambda t: datetime.fromtimestamp(t, timezone.utc).strftime("%Y%m%d%H%M%S +0000")
    category = dict(live_categories)
    out = ['<?xml version="1.0" encoding="UTF-8"?>\n<tv>\n']
    for c in channels:
        out.append(f'<channel id="{c[3]}.demo"><display-name>{escape(c[1])}</display-name>'
                   f'<icon src="{art(f"logo-{c[3]}.png")}"/></channel>\n')
    for i, c in enumerate(channels):
        # Stagger the channels so the grid doesn't line up in columns.
        t, n = start - (i % 3) * 15 * 60, i
        while t < end:
            title, minutes, desc = c[6][n % len(c[6])]
            out.append(f'<programme start="{ts(t)}" stop="{ts(t + minutes * 60)}" channel="{c[3]}.demo">'
                       f'<title>{escape(title)}</title><desc>{escape(desc)}</desc>'
                       f'<category>{category[c[2]]}</category></programme>\n')
            t += minutes * 60
            n += 1
    out.append("</tv>\n")
    return "".join(out).encode()


def stream_url(path):
    """The test stream for /live/…, /movie/…, /series/… or /timeshift/… URLs, which end in <id>.<ext>."""
    item = int(os.path.splitext(path.rsplit("/", 1)[-1])[0] or 0)
    for c in channels:
        if c[0] == item: return c[5]
    for m in movies:
        if m[0] == item: return m[10]
    return BUNNY


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlparse(self.path)
        if url.path.endswith("/player_api.php"):
            self.send(json.dumps(api(parse_qs(url.query))).encode(), "application/json")
        elif url.path.endswith("/xmltv.php"):
            self.send(guide(), "application/xml")
        elif url.path.startswith("/art/"):
            name = os.path.basename(url.path)
            path = os.path.join(art_dir, name)
            if not os.path.isfile(path): return self.send_error(404)
            with open(path, "rb") as f:
                self.send(f.read(), "image/png" if name.endswith(".png") else "image/jpeg")
        elif url.path.split("/")[1] in ("live", "movie", "series", "timeshift"):
            self.send_response(302)
            self.send_header("Location", stream_url(url.path))
            self.send_header("Content-Length", "0")
            self.end_headers()
        else:
            self.send_error(404)

    def send(self, body, content_type):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    print(f"Serving the screenshot Xtream server on {base}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
