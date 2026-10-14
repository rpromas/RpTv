// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AVFoundation
import RpTvKit
import SwiftUI

/// The active engine's video, with no controls.
struct PlayerVideoView: View {
    let engine: (any PlayerEngine)?

    var body: some View {
        if let engine = engine as? AVPlayerEngine {
            PlayerLayerView(playerLayer: engine.playerLayer)
                .accessibilityIdentifier("nativeVideo")
        } else if let engine = engine as? BridgedPlayerEngine {
            PlayerLayerView(playerLayer: engine.player.playerLayer)
                .accessibilityIdentifier("bridgedVideo")
        } else if let engine = engine as? FFmpegPlayerEngine {
            FFmpegVideoView(engine: engine)
                // Each engine draws into its own layer: a new engine (after a zap) needs a new view, not an update.
                .id(ObjectIdentifier(engine))
                .accessibilityIdentifier("ffmpegVideo")
        } else {
            Color.black
        }
    }
}

/// Hosts an engine's `AVPlayerLayer`, which the engine owns so Picture in Picture keeps working.
struct PlayerLayerView: UIViewRepresentable {
    let playerLayer: AVPlayerLayer

    func makeUIView(context: Context) -> HostView {
        HostView(playerLayer: playerLayer)
    }

    func updateUIView(_ view: HostView, context: Context) {
        view.playerLayer = playerLayer
    }

    final class HostView: UIView {
        var playerLayer: AVPlayerLayer {
            didSet {
                guard oldValue !== playerLayer else { return }
                oldValue.removeFromSuperlayer()
                layer.addSublayer(playerLayer)
                setNeedsLayout()
            }
        }

        init(playerLayer: AVPlayerLayer) {
            self.playerLayer = playerLayer
            super.init(frame: .zero)
            backgroundColor = .black
            layer.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func layoutSubviews() {
            super.layoutSubviews()
            // Follow rotation without the layer's implicit animation lagging behind.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
}
