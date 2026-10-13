# RpTv

A free, open-source IPTV player for iPhone and iPad, built with SwiftUI for iOS 26.

> RpTv is a player only. It doesn't provide any channels or content. Add your own M3U playlist or Xtream Codes account.

## Features

- **Sources:** M3U/M3U8 playlists (by URL or imported file) and Xtream Codes accounts. Keep several sources and switch between them.
- **Live TV:** categories and channels in a split view (sidebar on iPad, stack on iPhone), search, and channel logos.
- **Playback:** the native AVPlayer engine with Picture in Picture, AirPlay and background audio.
- **Privacy:** no analytics and no accounts. Xtream passwords are stored in the iOS keychain, never in the database.

### Roadmap

- [x] Phase 1: foundation. M3U and Xtream sources, Live TV browsing, native playback.
- [ ] Phase 2: full player. VLCKit fallback for MPEG-TS/MKV, custom controls, track selection, channel zapping.
- [ ] Phase 3: TV guide (XMLTV). Now/next, EPG grid, catch-up.
- [ ] Phase 4: movies and series. Continue Watching.
- [ ] Phase 5: favorites, global search, category management, parental controls.

## Building

Requirements: Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
xcodegen generate          # creates RpTv.xcodeproj from project.yml
open RpTv.xcodeproj
```

To run on a device, set your team in `project.yml` (`DEVELOPMENT_TEAM`) or in Xcode, and change `PRODUCT_BUNDLE_IDENTIFIER` to one you own.

## Testing

```sh
# Core logic (parsers, Xtream client, storage, sync), on macOS, takes a few seconds:
swift test --package-path Packages/RpTvKit

# Everything on the simulator, including the end-to-end UI test:
python3 -m http.server 8765 --directory Support &
TEST_RUNNER_RPTV_PLAYLIST_URL=http://localhost:8765/demo-playlist.m3u \
  xcodebuild -project RpTv.xcodeproj -scheme RpTv \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

`Support/demo-playlist.m3u` contains only Apple's public HLS sample streams. It also serves as the demo source for App Review.

## Project layout

```
App/                 iOS app target: SwiftUI screens and app state
Packages/RpTvKit/    Core library, platform independent and unit tested
  Models/            Source, MediaCategory, Channel
  M3U/               Streaming M3U parser
  Xtream/            Xtream Codes API client (tolerant of messy server JSON)
  Storage/           SQLite via GRDB: schema, migrations, queries
  Sync/              Downloads a source and replaces its catalog atomically
  Playback/          PlayerEngine protocol, engine selection, AVPlayer engine
UITests/             End-to-end UI tests
Support/             Demo playlist
project.yml          XcodeGen project spec
```

## License

[Mozilla Public License 2.0](LICENSE). Third-party libraries: [GRDB.swift](https://github.com/groue/GRDB.swift) (MIT) and [Nuke](https://github.com/kean/Nuke) (MIT).
