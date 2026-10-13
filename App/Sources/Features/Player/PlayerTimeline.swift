// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import RpTvKit
import SwiftUI

/// Shown instead of a scrubber for streams with no end.
struct LiveBadge: View {
    let isPaused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isPaused ? Color.gray : Color.red)
                .frame(width: 8, height: 8)
            Text("LIVE")
                .font(.caption.weight(.bold))
                .tracking(0.6)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Shown instead of a scrubber for a programme playing from the archive whose length the player doesn't know.
struct CatchupBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.caption.weight(.bold))
            Text("CATCH-UP")
                .font(.caption.weight(.bold))
                .tracking(0.6)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Elapsed time, a seek slider and remaining time. Seeks when the drag ends.
struct Scrubber: View {
    let engine: any PlayerEngine
    let duration: TimeInterval

    @Environment(PlayerChrome.self) private var chrome
    @State private var dragTime: TimeInterval?

    var body: some View {
        let time = min(dragTime ?? engine.currentTime, duration)
        HStack(spacing: 10) {
            Text(Self.format(time))
            Slider(value: Binding { time } set: { dragTime = $0 }, in: 0...duration) { editing in
                chrome.isScrubbing = editing
                if !editing, let dragTime {
                    engine.seek(to: dragTime)
                    self.dragTime = nil
                }
            }
            .tint(.white)
            .accessibilityLabel("Position")
            Text("-" + Self.format(duration - time))
        }
        .font(.caption.weight(.medium).monospacedDigit())
    }

    static func format(_ seconds: TimeInterval) -> String {
        let seconds = max(seconds, 0)
        return Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}
