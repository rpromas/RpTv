// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import RpTvKit
import SwiftUI

/// Near the end of an episode, offers the next one and plays it after a 10 s countdown. Reads the playback time
/// itself, so the rest of the player doesn't redraw as it ticks.
struct UpNextPrompt: View {
    let session: PlayerSession
    let compact: Bool

    /// How long before the end the prompt appears.
    static let leadTime: TimeInterval = 30

    var body: some View {
        if let next = session.nextEpisode, !session.isUpNextDismissed, let engine = session.coordinator.engine,
           let duration = engine.duration, duration > Self.leadTime * 2, duration - engine.currentTime <= Self.leadTime {
            UpNextCard(episode: next, compact: compact, isCounting: engine.state == .playing) {
                session.playNextEpisode()
            } onCancel: {
                session.isUpNextDismissed = true
            }
            // A fresh countdown for each episode.
            .id(next.stableKey)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }
}

private struct UpNextCard: View {
    let episode: Episode
    let compact: Bool
    /// The countdown waits while playback is paused.
    let isCounting: Bool
    let onPlay: () -> Void
    let onCancel: () -> Void

    @State private var secondsLeft = 10

    var body: some View {
        HStack(spacing: 12) {
            if !compact {
                EpisodeStill(url: episode.stillURL)
                    .frame(width: 120)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Up Next")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(episode.code) · \(episode.title)")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Button(action: onPlay) {
                        Label("Play in \(secondsLeft)", systemImage: "play.fill")
                            .contentTransition(.numericText(countsDown: true))
                            .monospacedDigit()
                    }
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("upNextPlayButton")
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("upNextCancelButton")
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: compact ? 280 : 420, alignment: .leading)
        .glassEffect(in: .rect(cornerRadius: 20))
        .task {
            while secondsLeft > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                if isCounting { withAnimation { secondsLeft -= 1 } }
            }
            onPlay()
        }
    }
}
