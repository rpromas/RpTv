// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import RpTvKit
import SwiftUI

/// The channels the player zaps through, with the one playing marked. Tapping a row switches to it.
struct ChannelZapList: View {
    let session: PlayerSession

    @State private var hasScrolledToCurrent = false

    var body: some View {
        ScrollViewReader { proxy in
            NowNextReader(database: session.database, channelIDs: session.zapList.channels.compactMap(\.id)) { nowNext, now in
                list(nowNext: nowNext, now: now)
            }
            // The list arrives after the player opens: scroll to the current channel once it's there.
            .onChange(of: session.zapList.channels.count, initial: true) {
                guard !hasScrolledToCurrent, session.zapList.currentIndex != nil else { return }
                hasScrolledToCurrent = true
                proxy.scrollTo(session.channel.stableKey, anchor: .center)
            }
            .onChange(of: session.channel.stableKey) { _, key in
                withAnimation { proxy.scrollTo(key, anchor: .center) }
            }
        }
    }

    private func list(nowNext: [Int64: NowNext], now: Date) -> some View {
        List(session.zapList.channels, id: \.stableKey) { channel in
            let isCurrent = channel.stableKey == session.channel.stableKey
            Button {
                session.zap(to: channel)
            } label: {
                HStack(spacing: 8) {
                    ChannelRow(channel: channel, nowNext: channel.id.flatMap { nowNext[$0] }, now: now)
                    if isCurrent {
                        Image(systemName: "speaker.wave.2.fill")
                            .symbolEffect(.variableColor.iterative)
                            .foregroundStyle(.tint)
                            .accessibilityLabel("Playing")
                    }
                }
            }
            .buttonStyle(.plain)
            .listRowBackground(isCurrent ? Color.accentColor.opacity(0.18) : Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

/// A glass tab on the trailing edge that pulls out the channel panel. Swiping left on the video does the same.
struct ChannelsTab: View {
    @Environment(PlayerChrome.self) private var chrome

    var body: some View {
        Button {
            chrome.openChannelPanel()
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "chevron.compact.left")
                    .font(.system(size: 20, weight: .semibold))
                Image(systemName: "list.bullet")
                    .font(.system(size: 17, weight: .semibold))
            }
            .frame(width: 40, height: 96)
            .contentShape(.capsule)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .accessibilityLabel("Channels")
        .accessibilityIdentifier("channelsButton")
    }
}

/// The channel list in a glass panel along the trailing edge, for the full-screen player.
struct ChannelPanel: View {
    let session: PlayerSession

    @Environment(PlayerChrome.self) private var chrome

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(session.context?.title ?? "Channels")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                PlayerIconButton(title: "Close Channels", systemImage: "xmark", size: 30, glass: false) {
                    chrome.closeChannelPanel()
                }
            }
            .padding(.leading, 20)
            .padding(.trailing, 12)
            .padding(.vertical, 10)
            ChannelZapList(session: session)
        }
        .frame(width: 340)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        // Swipe it back off to the right. Simultaneous, so the list still scrolls.
        .simultaneousGesture(
            DragGesture(minimumDistance: 24).onEnded { value in
                let dx = value.translation.width, dy = value.translation.height
                if dx > 60, dx > abs(dy) * 1.5 { chrome.closeChannelPanel() }
            }
        )
    }
}
