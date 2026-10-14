# RpTv

A free, open-source IPTV player for iPhone and iPad, built with SwiftUI for iOS 26.

> RpTv is a player only. It doesn't provide any channels or content. Add your own M3U playlist or Xtream Codes account.

## Features

- **Sources:** M3U/M3U8 playlists (by URL or imported file) and Xtream Codes accounts. Keep several sources and switch between them.
- **Live TV:** categories and channels in a split view (sidebar on iPad, stack on iPhone), search, and channel logos.
- **Movies:** Xtream VOD, and the movies an M3U playlist mixes in with its channels. A poster grid by category, sorted by date added, name or rating, with search, and a details screen (plot, cast, runtime, trailer).
- **Series:** Xtream series, and the episodes an M3U playlist names like "Show S01E02", gathered into series. Seasons and episodes with stills, plots and runtimes, and an Up Next prompt near the end of each episode. Movies and series share the Library tab.
- **Continue Watching:** movies and episodes remember where you stopped, resume from there, and count as watched at 95 %. A Continue Watching row at the top of Movies and Series, and a watched check on every episode.
- **Favorites and recents:** star channels, movies and series from any list, poster or the player, reorder favorite channels by dragging, and find what you watched last. Optionally resume the last channel at launch.
- **Search:** one search across all sources for channels, movies, series and guide programmes, matching word prefixes and ignoring accents ("cafe" finds "Café").
- **TV guide:** XMLTV guides (from the playlist, the Xtream account, or a URL you set), now/next on every channel, and a guide grid with programme details and reminders.
- **Catch-up:** watch past programmes from the provider's archive: Xtream timeshift, and M3U `catchup` modes (`default`, `append`, `shift`, `flussonic`).
- **Categories:** hide, rename and drag categories into your own order, per source. Your changes survive refreshes.
- **Parental controls:** a 4-digit PIN, with optional Face ID or Touch ID, locks the categories you pick. Their channels, movies and series stay out of lists, search, favorites and recents until the PIN is entered, and lock again when the app goes to the background.
- **Sources:** edit a source's address, login, guide, headers and player at any time. Xtream accounts show their status, expiry date and connections, with a warning a week before they expire. Export your sources to a JSON file (without passwords) and import them on another device.
- **Settings:** a default player, the live buffer, preferred audio and subtitle languages, how often catalogs and guides refresh, light or dark appearance, and clearing the image cache or guide data.
- **Playback:** the native AVPlayer engine with Picture in Picture, AirPlay and background audio, and RpTv's own FFmpeg player for raw MPEG-TS, MKV, RTMP and other formats AVPlayer can't play: hardware decoding through VideoToolbox, deinterlacing, multiple audio tracks, text and bitmap subtitles, US closed captions (CEA-608), clock drift correction on live channels, and Picture in Picture. RpTv picks the engine per stream and switches to FFmpeg automatically when the native player fails. You can also force one engine per source. With AirPlay on, streams AVPlayer can't open are converted to HLS on the device so the TV gets their video.
- **Privacy:** no analytics and no accounts. Xtream passwords are stored in the iOS keychain, never in the database.

### Roadmap

- [x] Phase 1: foundation. M3U and Xtream sources, Live TV browsing, native playback.
- [x] Phase 2: full player.
  - [x] FFmpeg engine with automatic fallback for MPEG-TS/MKV (replaced VLCKit).
  - [x] Custom controls, track selection, channel zapping, AirPlay bridge.
- [x] Phase 3: TV guide (XMLTV). Now/next, EPG grid, catch-up.
- [x] Phase 4: movies and series.
  - [x] Movies (VOD).
  - [x] Series and Continue Watching.
- [x] Phase 5: library and settings.
  - [x] Favorites, recently watched and global search.
  - [x] Category management, parental controls, settings, account status, source export and import.

## Building

Requirements: Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and NASM (`brew install xcodegen nasm`).

FFmpeg is built from source, from the `Vendor/FFmpeg` submodule. Build it once after cloning, and again whenever the submodule moves to a new tag:

```sh
git submodule update --init --depth 1   # FFmpeg sources, pinned to a release tag
Scripts/build-ffmpeg.sh                 # Packages/FFmpeg/FFmpeg.xcframework (iOS, simulator, macOS; a few minutes)
xcodegen generate                       # creates RpTv.xcodeproj from project.yml
open RpTv.xcodeproj
```

To run on a device, create `Config/Local.xcconfig` with `DEVELOPMENT_TEAM = <your team ID>` (it isn't checked in, and `xcodegen generate` keeps it), and change `PRODUCT_BUNDLE_IDENTIFIER` to one you own. A team picked in Xcode's Signing tab is lost the next time the project is generated.

## Testing

```sh
# Core logic (parsers, Xtream client, storage, sync), on macOS, takes a few seconds:
swift test --package-path Packages/RpTvKit

# The FFmpeg build has the codecs the app needs and no GPL parts:
swift test --package-path Packages/FFmpeg

# The AirPlay bridge (FFmpeg pipeline on synthetic test streams, HLS server):
swift test --package-path Packages/StreamBridge

# Everything on the simulator, including the end-to-end UI tests:
python3 -m http.server 8765 --directory Support &
TEST_RUNNER_RPTV_PLAYLIST_URL=http://localhost:8765/demo-playlist.m3u \
  xcodebuild -project RpTv.xcodeproj -scheme RpTv \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

The guide test needs a large generated guide instead (1,000 channels, two weeks; it also waits for a reminder, so it takes a few minutes):

```sh
Scripts/make-demo-guide.py /tmp/rptv-guide
python3 -m http.server 8765 --directory /tmp/rptv-guide &
TEST_RUNNER_RPTV_GUIDE_PLAYLIST_URL=http://127.0.0.1:8765/playlist.m3u \
  xcodebuild -project RpTv.xcodeproj -scheme RpTv \
  -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:RpTvUITests/GuideUITests test
```

`testTransportStreamPlaysThroughBridge` launches with `--prefer-bridge`, which turns the AirPlay bridge on without AirPlay (the simulator has none).

`Support/demo-playlist.m3u` contains only Apple's public sample streams: HLS, plus one raw MPEG-TS segment that exercises the FFmpeg engine, and a WWDC session MP4 that shows up under Movies. It also serves as the demo source for App Review.

## Project layout

```
App/                 iOS app target: SwiftUI screens and app state
Packages/RpTvKit/    Core library, platform independent and unit tested
  Models/            Source, MediaCategory, Channel, Movie, Programme
  M3U/               Streaming M3U parser
  EPG/               XMLTV parser, guide matching, guide grid time scale
  Xtream/            Xtream Codes API client (tolerant of messy server JSON)
  Storage/           SQLite via GRDB: schema, migrations, queries
  Sync/              Downloads a source and replaces its catalog atomically
  Playback/          PlayerEngine protocol, engine selection and fallback, AVPlayer engine, catch-up URLs
Packages/FFmpeg/     FFmpeg as a Swift package (the XCFramework is built by Scripts/build-ffmpeg.sh)
Packages/StreamBridge/  AirPlay bridge: converts streams AVPlayer can't open into local HLS
Vendor/FFmpeg/       FFmpeg sources (git submodule, pinned to a release tag)
Scripts/             Build scripts, demo guide generator
UITests/             End-to-end UI tests
Support/             Demo playlist
project.yml          XcodeGen project spec
Config/              Build settings (signing; your Local.xcconfig with the team ID)
```

## License

[Mozilla Public License 2.0](LICENSE). Third-party libraries: [GRDB.swift](https://github.com/groue/GRDB.swift) (MIT), [Nuke](https://github.com/kean/Nuke) (MIT) and [FFmpeg](https://ffmpeg.org) (LGPL-2.1, LGPL components only, dynamically linked). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), which also explains how to rebuild RpTv with a modified FFmpeg.
