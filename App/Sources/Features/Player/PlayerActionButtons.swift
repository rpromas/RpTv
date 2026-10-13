// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AVKit
import RpTvKit
import SwiftUI

/// A round player button. `glass` gives it its own Liquid Glass circle; without it, it sits inside a glass bar.
struct PlayerIconButton: View {
    let title: String
    let systemImage: String
    var size: CGFloat = 36
    var glass = true
    let action: () -> Void

    var body: some View {
        if glass {
            button.buttonStyle(.glass).buttonBorderShape(.circle)
        } else {
            button.buttonStyle(.plain)
        }
    }

    private var button: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.45, weight: .semibold))
                .frame(width: size, height: size)
                .contentShape(.circle)
        }
        .accessibilityLabel(title)
    }
}

/// Picks the audio track and subtitles. Hidden when there's nothing to pick.
struct TracksMenu: View {
    let engine: any PlayerEngine

    @Environment(PlayerChrome.self) private var chrome

    var body: some View {
        if engine.audioTracks.count > 1 || !engine.subtitleTracks.isEmpty {
            Menu {
                if engine.audioTracks.count > 1 {
                    Section("Audio") {
                        Picker("Audio", selection: selection(engine.audioTracks)) {
                            ForEach(engine.audioTracks) { Text($0.name).tag(Optional($0.id)) }
                        }
                        .pickerStyle(.inline)
                    }
                }
                if !engine.subtitleTracks.isEmpty {
                    Section("Subtitles") {
                        Picker("Subtitles", selection: selection(engine.subtitleTracks)) {
                            Text("Off").tag(String?.none)
                            ForEach(engine.subtitleTracks) { Text($0.name).tag(Optional($0.id)) }
                        }
                        .pickerStyle(.inline)
                    }
                }
            } label: {
                Image(systemName: "captions.bubble")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36)
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Audio and Subtitles")
        }
    }

    /// The selected track's ID; setting it selects that track, or turns subtitles off for `nil`.
    private func selection(_ tracks: [MediaTrack]) -> Binding<String?> {
        Binding {
            tracks.first(where: \.isSelected)?.id
        } set: { id in
            chrome.interacted()
            if let track = tracks.first(where: { $0.id == id }) {
                engine.select(track: track)
            } else {
                engine.disableSubtitles()
            }
        }
    }
}

/// Cycles fit → fill → stretch.
struct AspectButton: View {
    let engine: any PlayerEngine
    var glass = true

    @Environment(PlayerChrome.self) private var chrome

    var body: some View {
        PlayerIconButton(title: "Aspect Ratio: \(engine.videoGravity.title)", systemImage: "aspectratio", glass: glass) {
            engine.videoGravity = engine.videoGravity.next
            chrome.showHUD(engine.videoGravity.title)
            chrome.interacted()
        }
    }
}

/// Playback speed, for streams with a known length.
struct SpeedMenu: View {
    let engine: any PlayerEngine

    @Environment(PlayerChrome.self) private var chrome

    private static let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    var body: some View {
        Menu {
            Picker("Speed", selection: Binding {
                engine.rate
            } set: { rate in
                chrome.interacted()
                engine.rate = rate
            }) {
                ForEach(Self.rates, id: \.self) { Text(Self.label($0)).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Text(Self.label(engine.rate))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .frame(minWidth: 36, minHeight: 36)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Playback Speed")
    }

    private static func label(_ rate: Float) -> String {
        "\(rate.formatted(.number.precision(.fractionLength(0...2))))×"
    }
}

struct PictureInPictureButton: View {
    let engine: any PlayerEngine

    var body: some View {
        if engine.supportsPictureInPicture {
            PlayerIconButton(title: "Picture in Picture", systemImage: "pip.enter") {
                engine.startPictureInPicture()
            }
        }
    }
}

/// The system AirPlay picker in a glass circle.
struct RoutePickerButton: View {
    var body: some View {
        RoutePickerView()
            .frame(width: 36, height: 36)
            .padding(6)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("AirPlay")
    }

    private struct RoutePickerView: UIViewRepresentable {
        func makeUIView(context: Context) -> AVRoutePickerView {
            let view = AVRoutePickerView()
            view.prioritizesVideoDevices = true
            view.tintColor = .white
            return view
        }

        func updateUIView(_ view: AVRoutePickerView, context: Context) {}
    }
}

extension VideoGravity {
    var title: String {
        switch self {
        case .fit: "Fit"
        case .fill: "Fill"
        case .stretch: "Stretch"
        }
    }
}
