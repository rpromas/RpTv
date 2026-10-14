// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest

/// Sets a parental PIN, locks a category of the demo playlist, and opens it again with the PIN.
final class ParentalControlsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testLockedCategoryAsksForThePIN() throws {
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
        app.buttons["Add"].tap()
        XCTAssertTrue(app.buttons["Dolby Vision & Atmos"].firstMatch.waitForExistence(timeout: 30))

        // Choose a PIN, typed twice.
        app.buttons["Settings"].firstMatch.tap()
        attach(app, "Settings")
        let parental = app.buttons["parentalControlsButton"]
        for _ in 0..<5 where !parental.isHittable {
            app.collectionViews.firstMatch.swipeUp()
        }
        parental.tap()
        app.buttons["setPINButton"].tap()
        enterPIN("1234", in: app)
        XCTAssertTrue(app.staticTexts["Confirm PIN"].waitForExistence(timeout: 3))
        attach(app, "Confirm PIN")
        enterPIN("1234", in: app)
        XCTAssertTrue(app.buttons["Change PIN"].waitForExistence(timeout: 3))
        attach(app, "Parental Controls")
        app.navigationBars.buttons.firstMatch.tap()

        // Lock the Dolby category. The PIN was just entered, so it isn't asked again.
        let details = app.buttons["Details"].firstMatch
        for _ in 0..<5 where !details.isHittable {
            app.collectionViews.firstMatch.swipeDown()
        }
        details.tap()
        attach(app, "Source Details")
        app.buttons["editSourceButton"].tap()
        XCTAssertTrue(app.navigationBars["Edit Source"].waitForExistence(timeout: 3))
        attach(app, "Edit Source")
        app.buttons["Cancel"].tap()
        app.buttons["Live TV Categories"].tap()
        let dolby = app.descendants(matching: .any)["category-Dolby Samples"].firstMatch
        XCTAssertTrue(dolby.waitForExistence(timeout: 5))
        dolby.swipeLeft()
        app.buttons["Lock"].tap()
        XCTAssertTrue(app.images["Locked"].waitForExistence(timeout: 3))
        attach(app, "Categories")

        // Close the session's unlock: the category's channels leave All Channels. Scrolling Settings back to the
        // top brings back the tab bar it minimized.
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.collectionViews.firstMatch.swipeDown()
        app.buttons["Live TV"].firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        let relock = app.buttons["relockButton"]
        XCTAssertTrue(relock.waitForExistence(timeout: 3))
        relock.tap()
        app.buttons["All Channels"].tap()
        XCTAssertTrue(app.buttons["BipBop Basic"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Dolby Vision & Atmos"].exists)
        app.navigationBars.buttons.firstMatch.tap()

        // Opening the category asks for the PIN. A wrong one is refused.
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Dolby Samples'")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Enter PIN"].waitForExistence(timeout: 3))
        enterPIN("0000", in: app)
        XCTAssertTrue(app.staticTexts["Wrong PIN. 4 attempts left."].waitForExistence(timeout: 3))
        attach(app, "Wrong PIN")
        enterPIN("1234", in: app)
        XCTAssertTrue(app.buttons["Dolby Vision & Atmos"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func enterPIN(_ pin: String, in app: XCUIApplication) {
        for digit in pin {
            app.buttons[String(digit)].tap()
        }
    }
}
