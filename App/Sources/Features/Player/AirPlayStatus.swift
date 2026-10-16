// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AVFoundation
import Observation
import RpTvKit
import SwiftUI

/// The AirPlay device audio is going to, if any.
@MainActor
@Observable
final class AirPlayRoute {
    private(set) var deviceName: String?

    @ObservationIgnored private var task: Task<Void, Never>?

    init() {
        refresh()
        task = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AVAudioSession.routeChangeNotification) {
                self?.refresh()
            }
        }
    }

    isolated deinit {
        task?.cancel()
    }

    private func refresh() {
        deviceName = AVAudioSession.sharedInstance().currentRoute.outputs.first { $0.portType == .airPlay }?.portName
    }
}

/// Replaces the empty video area while AirPlay shows the stream on a TV.
struct AirPlayPlaceholder: View {
    let deviceName: String?
    let compact: Bool

    var body: some View {
        VStack(spacing: compact ? 6 : 12) {
            Image(systemName: "tv.and.mediabox")
                .font(.system(size: compact ? 36 : 56, weight: .light))
            Text(deviceName.map { "Playing on \($0)" } ?? "Playing on AirPlay")
                .font(compact ? .headline : .title3.weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .accessibilityElement(children: .combine)
    }
}

/// Shown when a stream plays on the FFmpeg player during AirPlay, which then carries only its sound.
struct AirPlaySoundOnlyNotice: View {
    let deviceName: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "airplay.audio")
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sound only on \(deviceName)")
                    .font(.subheadline.weight(.semibold))
                Text("This stream couldn't be converted for AirPlay, so only its sound plays there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }
}
