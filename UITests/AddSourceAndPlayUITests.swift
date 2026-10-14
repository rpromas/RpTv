// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest

/// End-to-end: add a playlist, browse to a channel and play it on each engine.
///
/// Needs a reachable playlist. Serve `Support/demo-playlist.m3u` and pass its URL:
/// `TEST_RUNNER_RPTV_PLAYLIST_URL=http://localhost:8000/demo-playlist.m3u xcodebuild test …`
final class AddSourceAndPlayUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testAddPlaylistAndPlayChannel() throws {
        let app = try launchWithDemoPlaylist()

        // iPhone opens straight on "All Channels"; iPad shows categories and channels side by side.
        let channel = app.buttons["BipBop Advanced (fMP4)"].firstMatch
        XCTAssertTrue(channel.waitForExistence(timeout: 30), "Channels didn't appear after adding the source")
        attach(app, "Channels")
        channel.tap()

        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10))
        let video = app.descendants(matching: .any)["nativeVideo"]
        XCTAssertTrue(video.waitForExistence(timeout: 5))
        // Let the stream start before capturing it.
        sleep(8)
        XCTAssertFalse(app.staticTexts["Can't Play This Stream"].exists)

        // The controls have faded by now: bring them back and pause.
        let playPause = showControls(app, over: video)
        XCTAssertEqual(playPause.label, "Pause")
        playPause.tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
        attach(app, "Player (portrait)")
        playPause.tap()

        XCUIDevice.shared.orientation = .landscapeLeft
        waitForLandscape(app, true)
        _ = showControls(app, over: video)
        XCTAssertTrue(app.buttons["Close"].exists)
        attach(app, "Player (landscape)")

        // The channel list slides in from the right, from its tab or a swipe to the left.
        app.buttons["channelsButton"].tap()
        let closeChannels = app.buttons["Close Channels"]
        XCTAssertTrue(closeChannels.waitForExistence(timeout: 3))
        attach(app, "Channel panel")
        closeChannels.tap()
        // Start clear of the transport buttons in the middle.
        video.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: video.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)))
        XCTAssertTrue(closeChannels.waitForExistence(timeout: 3))
        closeChannels.tap()

        // Locking the controls holds the screen in landscape.
        _ = showControls(app, over: video)
        app.buttons["Lock Controls"].tap()
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        var window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(window.width, window.height, "Rotated while locked")
        video.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        let unlock = app.buttons["Unlock Controls"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 2))
        unlock.tap()
        sleep(2)
        window = app.windows.firstMatch.frame
        XCTAssertLessThan(window.width, window.height, "Didn't rotate back after unlocking")

        // Swiping up moves to the next channel in the list.
        video.swipeUp()
        XCTAssertTrue(app.descendants(matching: .any)["channelBanner"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["3 of 5"].exists)
        attach(app, "Zapped")
        video.swipeDown()
        XCTAssertTrue(app.staticTexts["2 of 5"].waitForExistence(timeout: 5))

        XCTAssertTrue(app.buttons["Close"].isHittable)
        app.buttons["Close"].tap()
    }

    /// AVPlayer can't play raw MPEG-TS, so this one goes through the FFmpeg player.
    @MainActor
    func testTransportStreamPlaysOnFFmpeg() throws {
        let app = try launchWithDemoPlaylist()

        let channel = app.buttons["BipBop Segment (MPEG-TS)"].firstMatch
        XCTAssertTrue(channel.waitForExistence(timeout: 30), "Channels didn't appear after adding the source")
        channel.tap()

        let video = app.descendants(matching: .any)["ffmpegVideo"]
        XCTAssertTrue(video.waitForExistence(timeout: 15))
        let playPause = app.buttons["playPauseButton"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "label == 'Pause'"), evaluatedWith: playPause)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.staticTexts["Can't Play This Stream"].exists)
        // Same controls as the native engine.
        _ = showControls(app, over: video)
        attach(app, "FFmpeg Player")
        app.buttons["Close"].tap()
    }

    /// With AirPlay on, raw MPEG-TS goes through the FFmpeg bridge into AVPlayer instead of the FFmpeg player.
    @MainActor
    func testTransportStreamPlaysThroughBridge() throws {
        let app = try launchWithDemoPlaylist(arguments: ["--prefer-bridge"])

        let channel = app.buttons["BipBop Segment (MPEG-TS)"].firstMatch
        XCTAssertTrue(channel.waitForExistence(timeout: 30), "Channels didn't appear after adding the source")
        channel.tap()

        let video = app.descendants(matching: .any)["bridgedVideo"]
        XCTAssertTrue(video.waitForExistence(timeout: 15))
        // Wait for the bridge's first segments and for AVPlayer to start on them.
        let playPause = app.buttons["playPauseButton"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 5))
        let playing = NSPredicate(format: "label == 'Pause'")
        expectation(for: playing, evaluatedWith: playPause)
        waitForExpectations(timeout: 15)
        XCTAssertFalse(app.staticTexts["Can't Play This Stream"].exists)
        attach(app, "Bridged Player")
        app.buttons["Close"].tap()
    }

    /// The demo playlist's MP4 lands in Movies rather than among the channels, and plays with a scrubber.
    @MainActor
    func testBrowseAndPlayMovie() throws {
        let app = try launchWithDemoPlaylist()
        XCTAssertTrue(app.buttons["BipBop Advanced (fMP4)"].firstMatch.waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["Discover Observation in SwiftUI (2023)"].exists, "The movie is listed as a channel")

        openLibrary(app, "Movies")
        let poster = app.buttons["Discover Observation in SwiftUI (2023), 2023"].firstMatch
        XCTAssertTrue(poster.waitForExistence(timeout: 10), "The movie isn't in the grid")
        attach(app, "Movies")
        poster.tap()

        let play = app.buttons["playMovieButton"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        attach(app, "Movie details")
        play.tap()

        let video = app.descendants(matching: .any)["nativeVideo"]
        XCTAssertTrue(video.waitForExistence(timeout: 10))
        sleep(6)
        XCTAssertFalse(app.staticTexts["Can't Play This Stream"].exists)
        let playPause = showControls(app, over: video)
        XCTAssertEqual(playPause.label, "Pause")
        // A movie has an end: skips and a scrubber instead of channel buttons and LIVE.
        XCTAssertTrue(app.buttons["Forward 10 Seconds"].exists)
        XCTAssertTrue(app.sliders["Position"].exists)
        XCTAssertFalse(app.buttons["nextChannelButton"].exists)
        attach(app, "Movie player")
        app.buttons["Close"].tap()
        XCTAssertTrue(play.waitForExistence(timeout: 5))
    }

    /// The demo playlist's two "Sample Sessions" episodes form a series. Near the end of the first, Up Next moves
    /// on to the second; closing the player then leaves the first watched, the second to resume, and the series
    /// under Continue Watching.
    @MainActor
    func testSeriesUpNextAndResume() throws {
        let app = try launchWithDemoPlaylist()
        XCTAssertTrue(app.buttons["BipBop Advanced (fMP4)"].firstMatch.waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Sample Sessions'")).firstMatch.exists,
                       "An episode is listed as a channel")

        openLibrary(app, "Series")
        let poster = app.buttons["Sample Sessions"].firstMatch
        XCTAssertTrue(poster.waitForExistence(timeout: 10), "The series isn't in the grid")
        attach(app, "Series")
        poster.tap()

        let play = app.buttons["playSeriesButton"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        XCTAssertEqual(play.label, "Play S1 E1")
        XCTAssertTrue(app.buttons["episode-S1 E2"].exists)
        attach(app, "Series details")
        play.tap()

        let video = app.descendants(matching: .any)["nativeVideo"]
        XCTAssertTrue(video.waitForExistence(timeout: 10))
        sleep(6)
        XCTAssertFalse(app.staticTexts["Can't Play This Stream"].exists)
        _ = showControls(app, over: video)
        let position = app.sliders["Position"]
        XCTAssertTrue(position.waitForExistence(timeout: 5), "An episode has no scrubber")
        attach(app, "Episode player")

        // Near the end, Up Next offers the second episode.
        position.adjust(toNormalizedSliderPosition: 0.99)
        let upNext = app.buttons["upNextPlayButton"]
        XCTAssertTrue(upNext.waitForExistence(timeout: 15), "Up Next didn't appear near the end")
        attach(app, "Up Next")
        upNext.tap()
        XCTAssertFalse(upNext.waitForExistence(timeout: 3) && upNext.isHittable, "Up Next stayed up")

        // Long enough for the second episode's position to be worth resuming.
        sleep(14)
        _ = showControls(app, over: video)
        app.buttons["Close"].tap()

        let resume = app.buttons["playSeriesButton"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "label == 'Resume S1 E2'"), evaluatedWith: resume)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["episode-S1 E1"].label.contains("Watched"), "The first episode isn't marked watched")
        attach(app, "Series details after watching")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.descendants(matching: .any)["continueWatchingShelf"].waitForExistence(timeout: 5),
                      "The series isn't under Continue Watching")
        attach(app, "Continue Watching")
    }

    /// Star a channel, find it under Favorites, watch it, find it under Recent, then search for another one.
    @MainActor
    func testFavoritesRecentsAndSearch() throws {
        let app = try launchWithDemoPlaylist()

        let channel = app.buttons["BipBop Basic"].firstMatch
        XCTAssertTrue(channel.waitForExistence(timeout: 30), "Channels didn't appear after adding the source")
        channel.press(forDuration: 1)
        let addFavorite = app.buttons["Add to Favorites"]
        XCTAssertTrue(addFavorite.waitForExistence(timeout: 5))
        addFavorite.tap()

        // iPhone shows All Channels on top of the sidebar: go back to it.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["favoritesList"].tap()
        let favorite = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'BipBop Basic'")).firstMatch
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["BipBop Advanced (fMP4)"].exists)
        attach(app, "Favorites")

        // Watched for a few seconds, it counts as recent.
        favorite.tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10))
        sleep(7)
        let close = app.buttons["Close"]
        if !close.isHittable {
            app.descendants(matching: .any)["nativeVideo"].coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        }
        XCTAssertTrue(app.buttons["Remove from Favorites"].waitForExistence(timeout: 3), "The player doesn't show the channel as a favorite")
        close.tap()

        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["recentList"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'BipBop Basic'")).firstMatch.waitForExistence(timeout: 5))
        attach(app, "Recent")

        // Search matches word prefixes, in any order.
        app.buttons["Search"].firstMatch.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("fmp bip")
        let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'BipBop Advanced (fMP4)'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'BipBop Basic'")).firstMatch.exists)
        attach(app, "Search")

        // Movies are searched too. Star one from its details, and it's under Favorites in Movies.
        field.buttons["Clear text"].tap()
        field.typeText("observ")
        let movie = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Discover Observation in SwiftUI (2023)'")).firstMatch
        XCTAssertTrue(movie.waitForExistence(timeout: 5), "The movie isn't in the search results")
        movie.tap()
        let star = app.buttons["movieFavoriteButton"]
        XCTAssertTrue(star.waitForExistence(timeout: 5))
        star.tap()
        XCTAssertTrue(app.buttons["Remove from Favorites"].waitForExistence(timeout: 3))

        openLibrary(app, "Movies")
        // The poster's label starts with "Favorite" when it's starred.
        let poster = app.buttons["Favorite, Discover Observation in SwiftUI (2023), 2023"].firstMatch
        XCTAssertTrue(poster.waitForExistence(timeout: 5), "The poster isn't marked as a favorite")
        let favoritesChip = app.buttons["movieFavoritesChip"]
        favoritesChip.tap()
        expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: favoritesChip)
        waitForExpectations(timeout: 5)
        // Every poster there is a favorite, so none is badged.
        XCTAssertTrue(app.buttons["Discover Observation in SwiftUI (2023), 2023"].firstMatch.waitForExistence(timeout: 5),
                      "The starred movie isn't under Favorites")
        attach(app, "Favorite movies")
    }

    /// Waits for the window to finish rotating.
    @MainActor
    private func waitForLandscape(_ app: XCUIApplication, _ landscape: Bool) {
        for _ in 0..<20 {
            let frame = app.windows.firstMatch.frame
            if (frame.width > frame.height) == landscape { return }
            usleep(250_000)
        }
        XCTFail("The window didn't rotate")
    }

    /// Taps the video, away from the middle where play/pause sits, until the controls show. Returns play/pause.
    @MainActor
    private func showControls(_ app: XCUIApplication, over video: XCUIElement) -> XCUIElement {
        let playPause = app.buttons["playPauseButton"]
        // A tap toggles the controls, so one that lands just as they fade in or out needs another.
        for _ in 0..<3 where !playPause.waitForExistence(timeout: 1) {
            video.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        }
        XCTAssertTrue(playPause.waitForExistence(timeout: 2))
        return playPause
    }

    @MainActor
    private func launchWithDemoPlaylist(arguments: [String] = []) throws -> XCUIApplication {
        guard let playlistURL = ProcessInfo.processInfo.environment["RPTV_PLAYLIST_URL"] else {
            throw XCTSkip("Set RPTV_PLAYLIST_URL to run this test.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"] + arguments
        app.launch()

        app.buttons["Add Source"].tap()
        app.buttons["Playlist URL"].tap()
        let urlField = app.textFields["playlistURLField"]
        XCTAssertTrue(urlField.waitForExistence(timeout: 5))
        urlField.tap()
        urlField.typeText(playlistURL)
        attach(app, "Add Source")
        app.buttons["Add"].tap()
        return app
    }

    /// Opens the Library tab on its Movies or Series half.
    @MainActor
    private func openLibrary(_ app: XCUIApplication, _ half: String) {
        app.buttons["Library"].firstMatch.tap()
        let segment = app.segmentedControls["librarySwitcher"].buttons[half]
        XCTAssertTrue(segment.waitForExistence(timeout: 5))
        segment.tap()
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
