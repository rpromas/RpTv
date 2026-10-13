# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

RpTv is a free, open-source (MPL-2.0) IPTV player for iPhone and iPad, targeting iOS 26 and the App Store. It ships with no content: users add their own M3U playlist or Xtream Codes account.

## Commands

```sh
xcodegen generate                                   # regenerate RpTv.xcodeproj after changing project.yml or adding/removing files
swift test --package-path Packages/RpTvKit          # core unit tests on macOS (fast)
swift test --package-path Packages/RpTvKit --filter M3UParserTests   # a single suite
xcodebuild -project RpTv.xcodeproj -scheme RpTv -destination 'platform=iOS Simulator,name=iPhone 17' build
```
The UI test (`UITests/`) skips unless `TEST_RUNNER_RPTV_PLAYLIST_URL` points to a served copy of `Support/demo-playlist.m3u`. See README.

## Architecture

- `Packages/RpTvKit` holds all non-UI logic and must keep compiling on macOS so `swift test` works. Don't put UIKit or iOS-only SwiftUI there.
- `App/` holds the SwiftUI app. `AppModel` (@Observable, MainActor) owns the database, sync service, keychain and `nowPlaying`. Views read data through `AppDatabase.observe*` async streams (GRDB ValueObservation).
- Storage is GRDB/SQLite (`AppDatabase`). Schema changes go in a **new** migration in `AppDatabase.migrator`. Never edit a shipped migration.
- A sync (`SourceSyncService`) replaces a source's live catalog in one transaction (`replaceLiveCatalog`). `stableKey` identifies channels across resyncs.
- **Credentials never go in SQLite.** Xtream passwords live in the keychain (`CredentialStore`). Xtream stream URLs are built at play time by `PlaybackResolver`.
- Xtream JSON is inconsistent between servers. Decode with the `lossy*` helpers in `Support/LossyDecoding.swift`.
- Playback goes through the `PlayerEngine` protocol. `EngineSelector` picks AVPlayer (HLS/MP4) or VLC (TS/MKV/RTMP). The VLC engine is planned for Phase 2.

## Conventions

- Swift 6 with strict concurrency. Swift Testing (`@Test`) for unit tests, with fixtures in `Tests/RpTvKitTests/Fixtures`.
- Every source file starts with the MPL-2.0 header.
- Never add real channel lists or provider URLs anywhere in the repo.
