// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import RpTvKit
import SwiftUI

/// Briefly shows which channel the player just switched to, like a TV's on-screen display.
struct ChannelBanner: View {
    let session: PlayerSession

    var body: some View {
        NowPlayingTitle(session: session, fallback: session.zapList.positionLabel)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("channelBanner")
    }
}

/// A short message in a glass capsule, such as the new aspect mode.
struct PlayerHUD: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.headline)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
    }
}
