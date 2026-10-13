# Contributing to RpTv

Thanks for helping! A few ground rules:

- **No content.** Never add channel lists, provider links or anything that points to copyrighted streams, including in tests and screenshots. Use `Support/demo-playlist.m3u` or the fixtures.
- **Logic goes in `RpTvKit`.** Keep the app target thin, and add tests for parsers, networking and storage under `Packages/RpTvKit/Tests`.
- **Don't commit `RpTv.xcodeproj`.** Change `project.yml` and run `xcodegen generate`.
- **License headers.** New source files start with the MPL-2.0 header used throughout the repo.
- Run `swift test --package-path Packages/RpTvKit` before opening a pull request.

By contributing, you agree that your contributions are licensed under the MPL-2.0.
