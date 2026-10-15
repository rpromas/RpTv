// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest

/// App Store screenshots, saved as attachments named by their place in the listing ("1 Live TV").
///
/// `Scripts/screenshots.sh` runs a made-up Xtream server with Blender open movies (`Scripts/screenshot-server.py`),
/// runs this on the iPhone 6.9" and 6.3" and iPad 13" simulators, and exports the attachments. Pass the server's
/// URL as `TEST_RUNNER_RPTV_SCREENSHOT_SERVER`.
final class ScreenshotUITests: XCTestCase {
    @MainActor private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testScreenshots() throws {
        guard let server = ProcessInfo.processInfo.environment["RPTV_SCREENSHOT_SERVER"] else {
            throw XCTSkip("Set RPTV_SCREENSHOT_SERVER to run this test.")
        }
        XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()

        // Xtream Codes is the form's first type.
        app.buttons["Add Source"].tap()
        type(server, into: field(app.textFields, placeholder: "Server"))
        type("demo", into: field(app.textFields, placeholder: "Username"))
        type("demo", into: field(app.secureTextFields, placeholder: "Password"))
        // Search results show the source's name.
        type("Home", into: field(app.textFields, placeholder: "Name"))
        app.buttons["Add"].tap()

        // The guide imports after the catalog. Once the grid shows it, every list has its now/next.
        // "Open Cinema, Catch-up available"
        let channel = button(app, labelStartingWith: "Open Cinema")
        XCTAssertTrue(channel.waitForExistence(timeout: 60), "Channels didn't appear after adding the source")
        openTab(app, "Guide")
        XCTAssertTrue(button(app, labelStartingWith: "Watch Open Cinema").waitForExistence(timeout: 120), "The guide grid didn't appear")
        sleep(3)
        snapshot("3 Guide")

        openTab(app, "Live TV")
        XCTAssertTrue(channel.waitForExistence(timeout: 10))
        sleep(2)
        snapshot("1 Live TV")

        // The player in landscape, with its controls up (they don't fade out under --uitesting).
        channel.tap()
        let video = app.descendants(matching: .any)["nativeVideo"]
        XCTAssertTrue(video.waitForExistence(timeout: 10))
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(12)
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
        let switcher = app.segmentedControls["librarySwitcher"]
        XCTAssertTrue(switcher.buttons["Movies"].waitForExistence(timeout: 5))
        switcher.buttons["Movies"].tap()
        let movie = button(app, labelStartingWith: "Tears of Steel")
        XCTAssertTrue(movie.waitForExistence(timeout: 10))
        sleep(2)
        snapshot("4 Movies")

        // The plot comes with the details, fetched when the screen opens.
        movie.tap()
        XCTAssertTrue(app.buttons["playMovieButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(text(app, containing: "Amsterdam").waitForExistence(timeout: 10), "The movie's details didn't load")
        sleep(2)
        snapshot("5 Movie")

        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(switcher.buttons["Series"].waitForExistence(timeout: 5))
        switcher.buttons["Series"].tap()
        let series = button(app, labelStartingWith: "Caminandes")
        XCTAssertTrue(series.waitForExistence(timeout: 10))
        series.tap()
        XCTAssertTrue(app.descendants(matching: .any)["episode-S1 E1"].waitForExistence(timeout: 10),
                      "The series' episodes didn't load")
        sleep(2)
        snapshot("6 Series")

        openTab(app, "Settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        sleep(1)
        snapshot("8 Settings")

        // Last: searching puts the tab bar away.
        openTab(app, "Search")
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        // Search on the keyboard puts it away.
        field.typeText("bunny\n")
        XCTAssertTrue(button(app, labelStartingWith: "Big Buck Bunny").waitForExistence(timeout: 5))
        sleep(2)
        snapshot("7 Search")
    }

    @MainActor
    private func field(_ fields: XCUIElementQuery, placeholder: String) -> XCUIElement {
        fields.matching(NSPredicate(format: "placeholderValue BEGINSWITH %@", placeholder)).firstMatch
    }

    @MainActor
    private func type(_ text: String, into field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(text)
    }

    @MainActor
    private func button(_ app: XCUIApplication, labelStartingWith prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    @MainActor
    private func text(_ app: XCUIApplication, containing part: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", part)).firstMatch
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
