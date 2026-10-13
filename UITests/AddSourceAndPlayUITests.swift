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
        XCTAssertTrue(app.descendants(matching: .any)["nativeVideo"].waitForExistence(timeout: 5))
        // Let the stream start before capturing it.
        sleep(8)
        XCTAssertFalse(app.staticTexts["Can't Play This Stream"].exists)
        attach(app, "Player")
        app.buttons["Close"].tap()
    }

    /// AVPlayer can't play raw MPEG-TS, so this one goes through VLC.
    @MainActor
    func testTransportStreamPlaysOnVLC() throws {
        let app = try launchWithDemoPlaylist()

        let channel = app.buttons["BipBop Segment (MPEG-TS)"].firstMatch
        XCTAssertTrue(channel.waitForExistence(timeout: 30), "Channels didn't appear after adding the source")
        channel.tap()

        XCTAssertTrue(app.descendants(matching: .any)["vlcVideo"].waitForExistence(timeout: 15))
        // The sample is six seconds long: capture it while it plays.
        sleep(3)
        XCTAssertFalse(app.staticTexts["Can't Play This Stream"].exists)
        attach(app, "VLC Player")
        app.buttons["Close"].tap()
    }

    @MainActor
    private func launchWithDemoPlaylist() throws -> XCUIApplication {
        guard let playlistURL = ProcessInfo.processInfo.environment["RPTV_PLAYLIST_URL"] else {
            throw XCTSkip("Set RPTV_PLAYLIST_URL to run this test.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
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
