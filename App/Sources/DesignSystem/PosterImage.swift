// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import NukeUI
import RpTvKit
import SwiftUI

/// A 2:3 movie poster, or the title on a tinted card while there's none. Images are downsampled to the width
/// they're shown at, so a grid of thousands stays light on memory.
struct PosterImage: View {
    let url: String?
    let title: String
    /// The widest the poster is drawn, in points.
    var width: CGFloat = 180

    var body: some View {
        Color.clear
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                LazyImage(url: url.flatMap(URL.init(string:))) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        placeholder
                    }
                }
                .processors([.resize(width: width)])
            }
            .clipShape(.rect(cornerRadius: 10))
            .accessibilityHidden(true)
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(.fill.tertiary)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .padding(8)
        }
    }
}

/// A wide still behind a movie's header. Draws nothing while there's none.
struct BackdropImage: View {
    let url: String?

    var body: some View {
        // Fills the frame it's given. As the view itself, a filled image wider than the screen would make the
        // whole page that wide.
        Color.clear
            .overlay {
                LazyImage(url: url.flatMap(URL.init(string:))) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        Rectangle().fill(.fill.quaternary)
                    }
                }
                .processors([.resize(width: 1200)])
            }
            .clipped()
            .accessibilityHidden(true)
    }
}

extension Movie {
    /// "1999 · Sci-Fi · 2h 16m", leaving out what isn't known.
    var factsLine: String? {
        let genre = genre?.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) }
        let parts = [year.map(String.init), genre, runtime].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var runtime: String? {
        guard let durationSeconds, durationSeconds > 0 else { return nil }
        return Duration.seconds(durationSeconds).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }
}

extension Double {
    /// A provider rating such as "7.4".
    var ratingText: String { formatted(.number.precision(.fractionLength(1))) }
}
