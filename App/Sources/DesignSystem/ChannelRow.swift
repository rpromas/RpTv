// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import NukeUI
import RpTvKit
import SwiftUI

struct ChannelRow: View {
    let channel: Channel
    /// What's on, when the source has a guide for this channel.
    var nowNext: NowNext?
    /// The time the guide line and progress bar are drawn for.
    var now: Date = .now
    var isFavorite = false
    /// Shown under the name, for lists that mix sources.
    var sourceName: String?

    var body: some View {
        HStack(spacing: 14) {
            ChannelLogo(url: channel.logoURL, name: channel.name)
                .frame(width: 56, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(channel.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Favorite")
                    }
                }
                if let sourceName {
                    Text(sourceName)
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                }
                if let nowNext {
                    // Read out as the row's value, so the row's label stays the channel name.
                    GuideLines(nowNext: nowNext, now: now)
                        .accessibilityHidden(true)
                } else if let number = channel.number {
                    Text("Channel \(number)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if channel.canCatchUp {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Catch-up available")
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .accessibilityValue(nowNext?.now.map { "Now: \($0.title)" } ?? "")
    }
}

/// "Now" with a progress bar, then "Next", under a channel's name.
private struct GuideLines: View {
    let nowNext: NowNext
    let now: Date

    var body: some View {
        if let current = nowNext.now {
            Text("Now: \(current.title) · \(Self.timeRange(of: current))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let progress = current.progress(at: now) {
                ProgrammeProgressBar(progress: progress)
                    .frame(maxWidth: 160)
                    .padding(.vertical, 1)
            }
        }
        if let next = nowNext.next {
            Text("Next: \(next.title) · \(next.start.formatted(Self.time))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private static let time = Date.FormatStyle.dateTime.hour().minute()

    private static func timeRange(of programme: Programme) -> String {
        let start = programme.start.formatted(time)
        guard let stop = programme.stop else { return start }
        return "\(start)–\(stop.formatted(time))"
    }
}

/// How far into a programme we are, as a thin capsule.
struct ProgrammeProgressBar: View {
    let progress: Double

    var body: some View {
        Capsule()
            .fill(.quaternary)
            .overlay {
                Capsule()
                    .fill(.tint)
                    .scaleEffect(x: progress, anchor: .leading)
            }
            .frame(height: 3)
            .accessibilityHidden(true)
    }
}

struct ChannelLogo: View {
    let url: String?
    let name: String

    var body: some View {
        LazyImage(url: url.flatMap(URL.init(string:))) { state in
            if let image = state.image {
                image
                    .resizable()
                    .scaledToFit()
            } else {
                placeholder
            }
        }
        .processors([.resize(height: 80)])
        .padding(4)
        .background(.fill.tertiary, in: .rect(cornerRadius: 8))
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Text(initials)
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var initials: String {
        String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }
}
