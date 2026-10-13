# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

RpTv is a free, open-source (MPL-2.0) IPTV player for iPhone and iPad, targeting iOS 26 and the App Store. It ships with no content: users add their own M3U playlist or Xtream Codes account.

## Commands

```sh
Scripts/build-ffmpeg.sh                             # build Packages/FFmpeg/FFmpeg.xcframework from the Vendor/FFmpeg submodule (needed once, before the app builds)
xcodegen generate                                   # regenerate RpTv.xcodeproj after changing project.yml or adding/removing files
swift test --package-path Packages/RpTvKit          # core unit tests on macOS (fast)
swift test --package-path Packages/RpTvKit --filter M3UParserTests   # a single suite
swift test --package-path Packages/FFmpeg            # checks the FFmpeg build (codecs present, LGPL only)
swift test --package-path Packages/StreamBridge      # the AirPlay bridge: FFmpeg pipeline on synthetic fixtures, HLS server
xcodebuild -project RpTv.xcodeproj -scheme RpTv -destination 'platform=iOS Simulator,name=iPhone 17' build
```
The UI test (`UITests/`) skips unless `TEST_RUNNER_RPTV_PLAYLIST_URL` points to a served copy of `Support/demo-playlist.m3u`. See README.

## Architecture

- `Packages/RpTvKit` holds all non-UI logic and must keep compiling on macOS so `swift test` works. Don't put UIKit or iOS-only SwiftUI there.
- `App/` holds the SwiftUI app. `AppModel` (@Observable, MainActor) owns the database, sync service, keychain and the on-screen `playerSession` (a `PlayerSession`: coordinator, current channel, zap list). Views read data through `AppDatabase.observe*` async streams (GRDB ValueObservation).
- Storage is GRDB/SQLite (`AppDatabase`). Schema changes go in a **new** migration in `AppDatabase.migrator`. Never edit a shipped migration.
- A sync (`SourceSyncService`) replaces a source's live catalog in one transaction (`replaceLiveCatalog`). `stableKey` identifies channels across resyncs.
- **Credentials never go in SQLite.** Xtream passwords live in the keychain (`CredentialStore`). Xtream stream URLs are built at play time by `PlaybackResolver`.
- Xtream JSON is inconsistent between servers. Decode with the `lossy*` helpers in `Support/LossyDecoding.swift`.
- Playback goes through the `PlayerEngine` protocol. `PlaybackCoordinator` (in RpTvKit) picks the first engine (the source's `enginePreference`, then the engine that last worked for that item, then `EngineSelector` on the URL). It switches from AVPlayer to VLC when AVPlayer fails, or when a live stream hasn't started after 10 s. `PlayerScreen` renders whichever engine is active.
- `VLCPlayerEngine` lives in the **app target** (`App/Sources/Features/Player/`), not RpTvKit, so `swift test` never downloads or links VLCKit. Keep VLCKit imports out of the package.
- FFmpeg is built **from source**: the `Vendor/FFmpeg` git submodule (pinned to a release tag) is compiled by `Scripts/build-ffmpeg.sh` into a dynamic `FFmpeg.xcframework` (iOS, simulator, macOS) inside `Packages/FFmpeg`, which StreamBridge links (the app gets it through StreamBridge). LGPL components only: never add `--enable-gpl` or `--enable-nonfree`. Like VLCKit, keep it out of RpTvKit. When moving the submodule to a new tag, update the tag in `THIRD_PARTY_NOTICES.md`.
- **AirPlay bridge** (`Packages/StreamBridge`): VLC decodes on the device, so AirPlay only gets its sound. While AirPlay is on, `PlaybackCoordinator.prefersBridge` swaps VLC for `.bridge`: `BridgedPlayerEngine` (app target) runs `HLSBridge` (FFmpeg demux; copy H.264/HEVC/AAC/AC-3; re-encode other audio to AAC with AudioToolbox and other video to H.264 with VideoToolbox, deinterlacing with `bwdif`), serves the HLS with `HLSServer` on the Wi-Fi address, and plays it in an `AVPlayerEngine`, which AirPlay can hand to the TV. What to copy or re-encode is decided in `BridgePlan`.
- **StreamBridge must stay a dynamic library** (`type: .dynamic`, embedded in `project.yml`). VLCKit exports its own FFmpeg symbols; linking FFmpeg-calling code statically into the app binds some calls to VLCKit's copy (wrong version, no HTTPS). Never call FFmpeg from the app target directly: go through StreamBridge.
- VLCKit comes from VideoLAN's official SPM binary target (`https://code.videolan.org/videolan/VLCKit.git`), pinned with `exactVersion` in `project.yml` (currently `4.0.0-a25`, an alpha, since only 4.x alphas ship via SPM). It's LGPL-2.1 and must stay dynamically linked. When bumping it, update the tag in `THIRD_PARTY_NOTICES.md` too.

## Conventions

- Swift 6 with strict concurrency. Swift Testing (`@Test`) for unit tests, with fixtures in `Tests/RpTvKitTests/Fixtures`.
- Every source file starts with the MPL-2.0 header.
- Never add real channel lists or provider URLs anywhere in the repo.
