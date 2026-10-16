// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Keeps a live stream's buffer near its target by playing a little slower or faster.
///
/// A server's clock never quite matches the device's: at exactly 1× the buffer slowly drains or grows. Like VLC,
/// the player nudges its speed by 2 %, pitch-corrected by the audio renderer. The buffer level is averaged over
/// about ten seconds so network jitter doesn't move the speed.
struct LiveRateController {
    static let slow: Float = 0.98
    static let fast: Float = 1.02
    /// How many seconds the average follows.
    static let smoothing = 10.0

    /// Seconds of stream to keep read ahead of the playhead.
    let target: Double
    private(set) var rate: Float = 1
    private(set) var average: Double?

    init(target: Double) {
        self.target = max(target, 0.5)
    }

    /// Feeds the seconds read ahead of the playhead, `interval` seconds after the last call, and returns the
    /// speed to play at.
    mutating func update(buffered: Double, interval: Double) -> Float {
        guard buffered.isFinite else { return rate }
        let weight = min(1, interval / (Self.smoothing + interval))
        let average = self.average.map { $0 + (buffered - $0) * weight } ?? buffered
        self.average = average

        switch rate {
        case Self.slow where average >= target:
            rate = 1
        case Self.fast where average <= target * 2:
            rate = 1
        case 1 where average < target * 0.6:
            rate = Self.slow
        // Only a clear surplus: a few extra seconds are a cushion worth keeping.
        case 1 where average > max(target * 3, target + 5):
            rate = Self.fast
        default:
            break
        }
        return rate
    }

    /// Starts over, after a stall or anything else that empties the buffer.
    mutating func reset() {
        rate = 1
        average = nil
    }
}
