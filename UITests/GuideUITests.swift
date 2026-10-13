// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest

/// End-to-end: the TV guide grid, programme details, catch-up and reminders.
///
/// Needs a served playlist whose guide has a "Reminder Test" channel with 2-minute programmes titled by their
/// UTC start ("Reminder 1234Z"), and "Catch-up Shift" / "Catch-up Archive" channels with an "Earlier … Show"
/// three hours ago. Pass its URL as `TEST_RUNNER_RPTV_GUIDE_PLAYLIST_URL`.
final class GuideUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testGuideCatchupAndReminder() throws {
        guard let playlistURL = ProcessInfo.processInfo.environment["RPTV_GUIDE_PLAYLIST_URL"] else {
            throw XCTSkip("Set RPTV_GUIDE_PLAYLIST_URL to run this test.")
        }
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
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
        app.buttons["Add"].tap()

        // A tab bar button on iPhone, a sidebar cell on iPad in landscape.
        let guideTab = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Guide' AND (elementType == %d OR elementType == %d)",
                                                                             XCUIElement.ElementType.button.rawValue,
                                                                             XCUIElement.ElementType.cell.rawValue)).firstMatch
        XCTAssertTrue(guideTab.waitForExistence(timeout: 60))
        guideTab.tap()

        // The guide downloads after the catalog; the grid appears once it's imported.
        let shiftChannel = app.buttons["Watch Catch-up Shift"]
        XCTAssertTrue(shiftChannel.waitForExistence(timeout: 180), "The guide grid didn't appear")
        sleep(2)
        attach("Guide")

        // Scroll in both directions, then jump back to now.
        let grid = app.scrollViews.firstMatch
        grid.swipeLeft()
        grid.swipeLeft()
        grid.swipeUp()
        attach("Guide scrolled ahead and down")
        grid.swipeDown()
        app.buttons["guideNowButton"].tap()
        sleep(1)
        attach("Guide back at now")

        // Categories narrow the grid.
        app.buttons["Group 3"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Watch Channel 0002"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Watch Channel 0001"].exists)
        attach("Guide filtered")
        app.buttons["All"].firstMatch.tap()
        XCTAssertTrue(shiftChannel.waitForExistence(timeout: 10))

        // A past programme on a catch-up channel plays from the archive.
        watchFromStart(app, title: "Earlier Shift Show", in: grid)
        XCTAssertTrue(app.buttons["goLiveButton"].waitForExistence(timeout: 10))
        sleep(6)
        attach("Catch-up playing")
        app.buttons["goLiveButton"].tap()
        XCTAssertFalse(app.buttons["goLiveButton"].waitForExistence(timeout: 3))
        closePlayer(app)

        // This one's archive is on the test server, which logs the URL the player asks for.
        watchFromStart(app, title: "Earlier Archive Show", in: grid)
        sleep(3)
        attach("Archive requested")
        closePlayer(app)

        // A reminder for a programme 6–8 minutes away fires 5 minutes before it starts.
        app.buttons["guideNowButton"].tap()
        let start = Date.now.addingTimeInterval(6 * 60)
        let slotStart = Date(timeIntervalSince1970: (start.timeIntervalSince1970 / 120).rounded(.up) * 120)
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "HHmm"
        let title = "Reminder \(formatter.string(from: slotStart))Z"
        let cell = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10), "No cell for \(title)")
        cell.tap()
        let remind = app.buttons["remindMeButton"]
        XCTAssertTrue(remind.waitForExistence(timeout: 5))
        remind.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        XCTAssertTrue(app.buttons["Cancel Reminder"].waitForExistence(timeout: 5))
        attach("Reminder set")
        app.buttons["Close"].firstMatch.tap()

        let banner = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        let fireTime = slotStart.addingTimeInterval(-5 * 60).timeIntervalSinceNow
        XCTAssertTrue(banner.waitForExistence(timeout: max(fireTime, 0) + 60), "The reminder didn't fire")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Reminder fired"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Scrolls back until `title` is on screen, opens it and taps Watch from Start.
    @MainActor
    private func watchFromStart(_ app: XCUIApplication, title: String, in grid: XCUIElement) {
        app.buttons["guideNowButton"].tap()
        let cell = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10), "No cell for \(title)")
        // Off-screen cells can't report hittability, so go by their frame. The channel column covers the left.
        // A slow drag rather than a swipe, which would fling the grid hours past it.
        let from = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
        let to = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        for _ in 0..<12 where cell.frame.minX < grid.frame.minX + 220 {
            from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        cell.tap()
        let watch = app.buttons["watchFromStartButton"]
        XCTAssertTrue(watch.waitForExistence(timeout: 5))
        attach("Details: \(title)")
        watch.tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10))
    }

    /// Full screen, the controls fade after a few seconds: tap the video to bring Close back.
    @MainActor
    private func closePlayer(_ app: XCUIApplication) {
        let close = app.buttons["Close"]
        for _ in 0..<3 where !close.waitForExistence(timeout: 1) {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        }
        close.tap()
    }

    @MainActor
    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIApplication().screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
