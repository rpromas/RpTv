// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AVFoundation
import RpTvKit
import StreamBridge
import SwiftUI
import UIKit

/// The video of an ``FFmpegPlayerEngine``, with its subtitles.
struct FFmpegVideoView: View {
    let engine: FFmpegPlayerEngine

    var body: some View {
        ZStack {
            DisplayLayerView(displayLayer: engine.player.displayLayer)
            SubtitleOverlay(engine: engine)
        }
        // One element, like the other engines' video, so UI tests find a single view.
        .accessibilityElement(children: .ignore)
    }
}

/// Hosts the engine's display layer, which the engine owns so Picture in Picture keeps working.
private struct DisplayLayerView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> HostView {
        HostView(displayLayer: displayLayer)
    }

    func updateUIView(_ view: HostView, context: Context) {}

    final class HostView: UIView {
        private let displayLayer: AVSampleBufferDisplayLayer

        init(displayLayer: AVSampleBufferDisplayLayer) {
            self.displayLayer = displayLayer
            super.init(frame: .zero)
            backgroundColor = .black
            layer.addSublayer(displayLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func layoutSubviews() {
            super.layoutSubviews()
            // Follow rotation without the layer's implicit animation lagging behind.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            displayLayer.frame = bounds
            CATransaction.commit()
        }
    }
}

/// Draws the current subtitle over the picture: text near its bottom, bitmaps where the stream puts them.
/// Reads the subtitle itself, so the rest of the player doesn't redraw when it changes.
struct SubtitleOverlay: View {
    let engine: FFmpegPlayerEngine

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let picture = Self.pictureRect(engine.videoSize, in: bounds, gravity: engine.videoGravity)
            let visible = picture.intersection(bounds)
            if let cue = engine.subtitle, !visible.isNull {
                switch cue.content {
                case .text(let text):
                    Text(text)
                        .font(.system(size: max(14, visible.height * 0.055), weight: .semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 1)
                        .shadow(color: .black.opacity(0.8), radius: 3)
                        .frame(width: visible.width * 0.9)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, visible.height * 0.06)
                        .frame(width: visible.width, height: visible.height)
                        .position(x: visible.midX, y: visible.midY)
                case .images(let images):
                    ForEach(images.indices, id: \.self) { index in
                        let image = images[index]
                        Image(decorative: image.image, scale: 1)
                            .resizable()
                            .frame(width: image.frame.width * picture.width, height: image.frame.height * picture.height)
                            .position(x: picture.minX + image.frame.midX * picture.width,
                                      y: picture.minY + image.frame.midY * picture.height)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Where the picture lands in `bounds` with the given gravity.
    static func pictureRect(_ size: CGSize, in bounds: CGRect, gravity: VideoGravity) -> CGRect {
        guard size.width > 0, size.height > 0, gravity != .stretch else { return bounds }
        if gravity == .fit { return AVMakeRect(aspectRatio: size, insideRect: bounds) }
        let scale = max(bounds.width / size.width, bounds.height / size.height)
        let filled = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: bounds.midX - filled.width / 2, y: bounds.midY - filled.height / 2,
                      width: filled.width, height: filled.height)
    }
}
