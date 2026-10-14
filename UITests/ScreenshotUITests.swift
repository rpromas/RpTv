// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest

/// App Store screenshots, saved as attachments named by their place in the listing ("1 Live TV").
///
/// `Scripts/screenshots.sh` serves the demo playlist with a made-up guide (`Scripts/make-screenshot-content.py`),
/// runs this on the iPhone 6.9" and iPad 13" simulators, and exports the attachments. Pass the playlist's URL as
/// `TEST_RUNNER_RPTV_SCREENSHOT_PLAYLIST_URL`.
final class ScreenshotUITests: XCTestCase {
    @MainActor private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testScreenshots() throws {
        guard let playlistURL = ProcessInfo.processInfo.environment["RPTV_SCREENSHOT_PLAYLIST_URL"] else {
            throw XCTSkip("Set RPTV_SCREENSHOT_PLAYLIST_URL to run this test.")
        }
        XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()

        app.buttons["Add Source"].tap()
        app.buttons["Playlist URL"].tap()
        let urlField = app.textFields["playlistURLField"]
        XCTAssertTrue(urlField.waitForExistence(timeout: 5))
        urlField.tap()
        urlField.typeText(playlistURL)
        // Otherwise the source is named after the server, 127.0.0.1, which search results show.
        let nameField = app.textFields["Name (optional)"]
        nameField.tap()
        nameField.typeText("Demo")
        app.buttons["Add"].tap()

        // The guide imports after the catalog. Once the grid shows it, every list has its now/next.
        let channel = app.buttons["BipBop Advanced (fMP4)"].firstMatch
        XCTAssertTrue(channel.waitForExistence(timeout: 60), "Channels didn't appear after adding the source")
        openTab(app, "Guide")
        XCTAssertTrue(app.buttons["Watch BipBop Basic"].waitForExistence(timeout: 120), "The guide grid didn't appear")
        sleep(2)
        snapshot("3 Guide")

        openTab(app, "Live TV")
        XCTAssertTrue(channel.waitForExistence(timeout: 10))
        sleep(1)
        snapshot("1 Live TV")

        // The player in landscape, with its controls up (they don't fade out under --uitesting).
        channel.tap()
        let video = app.descendants(matching: .any)["nativeVideo"]
        XCTAssertTrue(video.waitForExistence(timeout: 10))
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(8)
        XCTAssertFalse(app.staticTexts["Can't Play This Stream"].exists)
        let playPause = app.buttons["playPauseButton"]
        for _ in 0..<3 where !playPause.waitForExistence(timeout: 1) {
            video.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        }
        XCTAssertTrue(playPause.exists)
        snapshot("2 Player")
        app.buttons["Close"].tap()
        XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
        sleep(1)

        openTab(app, "Library")
        let movies = app.segmentedControls["librarySwitcher"].buttons["Movies"]
        XCTAssertTrue(movies.waitForExistence(timeout: 5))
        movies.tap()
        let poster = app.buttons["Discover Observation in SwiftUI (2023), 2023"].firstMatch
        XCTAssertTrue(poster.waitForExistence(timeout: 10))
        poster.tap()
        XCTAssertTrue(app.buttons["playMovieButton"].waitForExistence(timeout: 5))
        sleep(1)
        snapshot("4 Movie")

        openTab(app, "Settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        sleep(1)
        snapshot("5 Settings")

        openTab(app, "Search")
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        // Search on the keyboard puts it away.
        field.typeText("bipbop\n")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'BipBop Basic'")).firstMatch
            .waitForExistence(timeout: 5))
        sleep(1)
        snapshot("6 Search")
    }

    /// A tab bar button, or a sidebar cell on iPad in landscape.
    @MainActor
    private func openTab(_ app: XCUIApplication, _ name: String) {
        let tab = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ AND (elementType == %d OR elementType == %d)", name,
            XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.cell.rawValue)).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "No \(name) tab")
        tab.tap()
    }

    /// The whole screen, status bar included, at the device's resolution.
    @MainActor
    private func snapshot(_ name: String) {
        // In landscape the screenshot is a portrait image marked as rotated. Draw it upright: App Store Connect
        // reads the pixels and ignores the orientation.
        let image = XCUIScreen.main.screenshot().image
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let upright = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }
        let attachment = XCTAttachment(image: upright, quality: .original)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
