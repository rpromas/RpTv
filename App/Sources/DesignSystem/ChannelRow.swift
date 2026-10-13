// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import NukeUI
import RpTvKit
import SwiftUI

struct ChannelRow: View {
    let channel: Channel

    var body: some View {
        HStack(spacing: 14) {
            ChannelLogo(url: channel.logoURL, name: channel.name)
                .frame(width: 56, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if let number = channel.number {
                    Text("Channel \(number)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if channel.catchupDays != nil {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Catch-up available")
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
}

/// A channel logo, falling back to the channel's initials.
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
