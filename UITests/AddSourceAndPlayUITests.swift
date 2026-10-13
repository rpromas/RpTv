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

    /// AVPlayer can't play raw MPEG-TS, so this one goes through VLC.
    @MainActor
    func testTransportStreamPlaysOnVLC() throws {
        let app = try launchWithDemoPlaylist()

        let channel = app.buttons["BipBop Segment (MPEG-TS)"].firstMatch
        XCTAssertTrue(channel.waitForExistence(timeout: 30), "Channels didn't appear after adding the source")
        channel.tap()

        let video = app.descendants(matching: .any)["vlcVideo"]
        XCTAssertTrue(video.waitForExistence(timeout: 15))
        // The sample is six seconds long: capture it while it plays.
        sleep(3)
        XCTAssertFalse(app.staticTexts["Can't Play This Stream"].exists)
        // Same controls as the native engine.
        _ = showControls(app, over: video)
        attach(app, "VLC Player")
        app.buttons["Close"].tap()
    }

    /// With AirPlay on, raw MPEG-TS goes through the FFmpeg bridge into AVPlayer instead of VLC.
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

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
