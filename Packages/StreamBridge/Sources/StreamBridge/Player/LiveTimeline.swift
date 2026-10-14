// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Turns a live stream's timestamps into one continuous timeline starting near zero.
///
/// IPTV timestamps jump: the encoder restarts, the server splices in another feed, or a reconnect resumes at a
/// later point. Played as they are, a jump forward freezes the picture until the clock catches up and a jump back
/// stalls it. Each stream's jump is detected on its own (audio and video arrive interleaved, so one crosses the
/// jump before the other), and streams that jump by about the same amount share an offset so they stay in sync.
struct LiveTimeline {
    /// A jump forward larger than this is a discontinuity rather than a gap in the stream.
    static let maxForwardGap = 2.0
    /// Decoding timestamps only go back at a discontinuity; a little slack covers sloppy muxers.
    static let maxBackwardStep = 1.0
    /// How close two streams' jumps must be to count as the same discontinuity.
    static let matchingJump = 3.0

    private struct Epoch {
        var jump: Double
        var offset: Double
    }

    private struct StreamState {
        var lastRaw: Double
        var offset: Double
    }

    private var streams: [Int32: StreamState] = [:]
    /// The offset of the latest discontinuity, given to streams that haven't sent anything yet.
    private var currentOffset: Double?
    /// Recent discontinuities, newest last, for the other streams to match when they cross them.
    private var epochs: [Epoch] = []

    /// The time in seconds on the continuous timeline of a packet at `raw` seconds (its decoding timestamp,
    /// or presentation timestamp when it has none) from `stream`.
    mutating func offset(forRaw raw: Double, stream: Int32) -> Double {
        guard var state = streams[stream] else {
            let offset = currentOffset ?? -raw
            currentOffset = offset
            streams[stream] = StreamState(lastRaw: raw, offset: offset)
            return offset
        }
        let jump = raw - state.lastRaw
        if jump > Self.maxForwardGap || jump < -Self.maxBackwardStep {
            if let epoch = epochs.last(where: { abs($0.jump - jump) < Self.matchingJump }) {
                state.offset = epoch.offset
            } else {
                // Carry on from where this stream was: the jump disappears from the timeline.
                let continued = state.lastRaw + state.offset
                state.offset = continued - raw
                epochs.append(Epoch(jump: jump, offset: state.offset))
                if epochs.count > 4 { epochs.removeFirst() }
                currentOffset = state.offset
            }
        }
        state.lastRaw = raw
        streams[stream] = state
        return state.offset
    }

    /// The offset for a sparse stream (subtitles), whose gaps say nothing about discontinuities: the latest one.
    mutating func sparseOffset(forRaw raw: Double) -> Double {
        if let currentOffset { return currentOffset }
        currentOffset = -raw
        return -raw
    }
}
