// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AVKit
import RpTvKit
import SwiftUI

/// Full-screen playback. AVPlayer streams use the system player UI for now, which brings PiP, AirPlay and
/// Now Playing integration with it. VLC streams show bare video until custom controls arrive.
struct PlayerScreen: View {
    let item: PlaybackItem

    @Environment(\.dismiss) private var dismiss
    @State private var coordinator = PlaybackCoordinator { kind in
        switch kind {
        case .native: AVPlayerEngine()
        case .vlc: VLCPlayerEngine()
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            video
                .ignoresSafeArea()

            if case .failed(let message) = coordinator.state {
                ContentUnavailableView {
                    Label("Can't Play This Stream", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { coordinator.retry() }
                        .buttonStyle(.glass)
                }
                .foregroundStyle(.white)
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Close")
            .padding()
        }
        .preferredColorScheme(.dark)
        .onAppear { coordinator.play(item) }
        .onDisappear { coordinator.stop() }
    }

    @ViewBuilder private var video: some View {
        if let engine = coordinator.engine as? AVPlayerEngine {
            SystemPlayerView(player: engine.player)
                .accessibilityIdentifier("nativeVideo")
        } else if let engine = coordinator.engine as? VLCPlayerEngine {
            VLCVideoSurface(engine: engine)
                .accessibilityIdentifier("vlcVideo")
                .overlay {
                    if engine.state == .loading || engine.state == .buffering {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                    }
                }
        }
    }
}

/// Wraps `AVPlayerViewController`.
struct SystemPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.videoGravity = .resizeAspect
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}
