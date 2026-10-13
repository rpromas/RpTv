// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Maps times to horizontal positions in the guide grid, where time runs left to right from `start`.
/// Positions are in points from the left edge of the timeline.
public struct GuideTimeScale: Sendable, Hashable {
    /// The ruler's step, and what `start` and `end` are rounded to.
    public static let markInterval: TimeInterval = 30 * 60
    /// Programme slots load in windows around the visible part of the grid, which moves in steps of this.
    public static let bucketLength: TimeInterval = 6 * 3600
    /// How far a load window reaches past its bucket on each side. Must be wider than the screen shows.
    public static let loadMargin: TimeInterval = 12 * 3600
    /// A programme with no known end is drawn an hour long, as in now/next.
    static let defaultDuration: TimeInterval = 3600

    /// The left edge of the timeline, on a half hour.
    public let start: Date
    /// The right edge of the timeline, on a half hour, after `start`.
    public let end: Date
    public let pointsPerMinute: Double

    /// A timeline covering `start` to `end`, widened to whole half hours.
    public init(start: Date, end: Date, pointsPerMinute: Double) {
        let interval = Self.markInterval
        let first = (start.timeIntervalSince1970 / interval).rounded(.down) * interval
        let last = max((end.timeIntervalSince1970 / interval).rounded(.up) * interval, first + interval)
        self.start = Date(timeIntervalSince1970: first)
        self.end = Date(timeIntervalSince1970: last)
        self.pointsPerMinute = pointsPerMinute
    }

    public var totalWidth: Double { x(for: end) }

    /// The position of `date`, which may fall outside the timeline.
    public func x(for date: Date) -> Double {
        date.timeIntervalSince(start) / 60 * pointsPerMinute
    }

    public func date(atX x: Double) -> Date {
        start.addingTimeInterval(x / pointsPerMinute * 60)
    }

    /// Where a programme's cell goes, cut off at the timeline's edges. Nil when it falls outside.
    public func frame(start: Date, stop: Date?) -> (x: Double, width: Double)? {
        let stop = stop ?? start.addingTimeInterval(Self.defaultDuration)
        let left = max(x(for: start), 0)
        let right = min(x(for: stop), totalWidth)
        guard right > left else { return nil }
        return (left, right - left)
    }

    /// The half-hour marks of the ruler from `from` to `to`, kept inside the timeline.
    public func marks(from: Date, to: Date) -> [Date] {
        let interval = Self.markInterval
        let first = max((from.timeIntervalSince1970 / interval).rounded(.down) * interval, start.timeIntervalSince1970)
        let last = min(to.timeIntervalSince1970, end.timeIntervalSince1970 - 1)
        guard first <= last else { return [] }
        return stride(from: first, through: last, by: interval).map { Date(timeIntervalSince1970: $0) }
    }

    /// The scroll offset that puts `date` `lead` after the left edge of a viewport `viewportWidth`
    /// points wide, without scrolling past either end.
    public func scrollX(toShow date: Date, lead: TimeInterval = 30 * 60, viewportWidth: Double) -> Double {
        let target = x(for: date.addingTimeInterval(-lead))
        return min(max(target, 0), max(totalWidth - viewportWidth, 0))
    }

    // MARK: - Load windows

    /// Which bucket the scroll offset `x` (the viewport's left edge) is in. Bucket numbers count from the
    /// Unix epoch, so they don't change when the timeline grows.
    public func bucket(forScrollX x: Double) -> Int {
        Int((date(atX: max(x, 0)).timeIntervalSince1970 / Self.bucketLength).rounded(.down))
    }

    /// The programmes to load while the viewport's left edge is in `bucket`: the bucket plus
    /// ``loadMargin`` on each side.
    public static func loadWindow(bucket: Int) -> DateInterval {
        let bucketStart = Double(bucket) * bucketLength
        return DateInterval(start: Date(timeIntervalSince1970: bucketStart - loadMargin),
                            end: Date(timeIntervalSince1970: bucketStart + bucketLength + loadMargin))
    }
}
