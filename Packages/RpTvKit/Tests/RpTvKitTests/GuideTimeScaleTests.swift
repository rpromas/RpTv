// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import RpTvKit

struct GuideTimeScaleTests {
    /// 2026-10-14 08:00 UTC, on a 6-hour bucket's second third (buckets start at 06:00).
    let eight = Date(timeIntervalSince1970: 1_791_964_800)

    private func at(_ hour: Double) -> Date { eight.addingTimeInterval((hour - 8) * 3600) }

    /// 08:00 to 10:00 at 4 points a minute: 480 points wide.
    private var scale: GuideTimeScale {
        GuideTimeScale(start: at(8 + 10.0 / 60), end: at(9 + 40.0 / 60), pointsPerMinute: 4)
    }

    @Test func widensToWholeHalfHours() {
        #expect(scale.start == at(8))
        #expect(scale.end == at(10))
        #expect(scale.totalWidth == 480)
        let empty = GuideTimeScale(start: at(8), end: at(8), pointsPerMinute: 4)
        #expect(empty.end == at(8.5))
    }

    @Test func mapsTimesToPositionsAndBack() {
        #expect(scale.x(for: at(8)) == 0)
        #expect(scale.x(for: at(8.5)) == 120)
        #expect(scale.x(for: at(7)) == -240)
        #expect(scale.date(atX: 120) == at(8.5))
        for x in stride(from: 0.0, through: 480, by: 37.5) {
            #expect(abs(scale.x(for: scale.date(atX: x)) - x) < 1e-9)
        }
    }

    @Test func framesProgrammesClippedToTheTimeline() throws {
        let inside = try #require(scale.frame(start: at(8.5), stop: at(9)))
        #expect(inside.x == 120 && inside.width == 120)
        let early = try #require(scale.frame(start: at(7), stop: at(8.5)))
        #expect(early.x == 0 && early.width == 120)
        let late = try #require(scale.frame(start: at(9.5), stop: at(11)))
        #expect(late.x == 360 && late.width == 120)
        // No end: an hour, then clipped.
        let open = try #require(scale.frame(start: at(9.5), stop: nil))
        #expect(open.x == 360 && open.width == 120)
        #expect(scale.frame(start: at(6), stop: at(8)) == nil)
        #expect(scale.frame(start: at(10), stop: at(11)) == nil)
    }

    @Test func listsHalfHourMarks() {
        #expect(scale.marks(from: at(8 + 10.0 / 60), to: at(9 + 10.0 / 60)) == [at(8), at(8.5), at(9)])
        #expect(scale.marks(from: at(6), to: at(12)) == [at(8), at(8.5), at(9), at(9.5)])
        #expect(scale.marks(from: at(11), to: at(12)).isEmpty)
    }

    @Test func scrollsToNowWithoutOverscrolling() {
        // Now at 09:00 sits half an hour in from the left edge.
        #expect(scale.scrollX(toShow: at(9), viewportWidth: 200) == 120)
        #expect(scale.scrollX(toShow: at(8), viewportWidth: 200) == 0)
        #expect(scale.scrollX(toShow: at(10), viewportWidth: 200) == 280)
        #expect(scale.scrollX(toShow: at(9), viewportWidth: 1000) == 0)
    }

    @Test func bucketsChangeEverySixHours() {
        let wide = GuideTimeScale(start: at(0), end: at(48), pointsPerMinute: 4)
        let morning = wide.bucket(forScrollX: wide.x(for: at(8)))
        #expect(morning == 82_961) // 06:00–12:00 UTC
        #expect(wide.bucket(forScrollX: wide.x(for: at(11.9))) == morning)
        #expect(wide.bucket(forScrollX: wide.x(for: at(12))) == morning + 1)
        #expect(wide.bucket(forScrollX: -50) == wide.bucket(forScrollX: 0))

        let window = GuideTimeScale.loadWindow(bucket: morning)
        #expect(window.start == at(-6))
        #expect(window.end == at(24))
    }

    @Test func loadWindowCoversTheViewport() {
        let wide = GuideTimeScale(start: at(-150), end: at(150), pointsPerMinute: 5)
        // An iPad landscape viewport shows about four hours; anything under the margin is covered.
        let viewport = 8.0 * 3600 / 60 * 5
        for x in stride(from: 0.0, through: wide.totalWidth - viewport, by: 731) {
            let window = GuideTimeScale.loadWindow(bucket: wide.bucket(forScrollX: x))
            #expect(window.start <= wide.date(atX: x))
            #expect(window.end >= wide.date(atX: x + viewport))
        }
    }
}
