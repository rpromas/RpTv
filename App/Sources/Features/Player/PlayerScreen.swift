// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import RpTvKit
import SwiftUI
import UIKit

/// The player. When the screen is taller than wide, the video docks at the top with the channel list below it;
/// otherwise the video fills the screen with the controls on top. Both engines get the same controls.
struct PlayerScreen: View {
    let session: PlayerSession

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var chrome = PlayerChrome()
    @State private var airPlay = AirPlayRoute()

    var body: some View {
        // The reader stays inside the safe area so it can report the insets; the content then extends past them.
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            let size = CGSize(width: proxy.size.width + insets.leading + insets.trailing,
                              height: proxy.size.height + insets.top + insets.bottom)
            let docked = size.height > size.width
            ZStack(alignment: .top) {
                Color.black
                // One stack for both layouts, so the video view (and the engine drawing into it) is never rebuilt
                // when the device rotates.
                VStack(spacing: 0) {
                    if docked {
                        PlayerTopBar(session: session, showsTitle: false, showsAspect: false, onClose: close)
                            .padding(.horizontal, 16)
                            .padding(.top, insets.top)
                            .padding(.bottom, 8)
                            .opacity(chrome.isLocked ? 0 : 1)
                            .disabled(chrome.isLocked)
                    }
                    stage(docked: docked, insets: docked ? EdgeInsets() : insets)
                        .frame(width: size.width, height: docked ? size.width * 9 / 16 : size.height)
                    if docked {
                        dockedChannels(bottomInset: insets.bottom)
                    }
                }

                if chrome.showsUnlockButton {
                    PlayerIconButton(title: "Unlock Controls", systemImage: "lock.fill", size: 44) { chrome.unlock() }
                        .padding(.top, max(insets.top, 16))
                        .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height)
            .ignoresSafeArea()
        }
        .environment(chrome)
        .preferredColorScheme(.dark)
        .statusBarHidden(!chrome.controlsVisible)
        .persistentSystemOverlays(chrome.controlsVisible ? .automatic : .hidden)
        .onAppear { session.start() }
        .onDisappear {
            session.stop()
            OrientationLock.unlock()
        }
        .task { await session.observeChannels() }
        .task { await session.observeEpisodes() }
        .onChange(of: session.coordinator.state, initial: true) { _, state in
            chrome.holdsControls = state != .playing
            if state == .paused { session.saveProgress() }
        }
        // The app may not come back from the background, so the position is saved on the way out.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { session.saveProgress() }
        }
        .onChange(of: session.zapCount) { chrome.showChannelBanner() }
        // With AirPlay on, streams the FFmpeg player would play go through the bridge instead, so the TV gets
        // their video.
        .onChange(of: airPlay.deviceName != nil, initial: true) { _, isOn in
            session.coordinator.setPrefersBridge(isOn || Self.alwaysBridges)
        }
        .alert("Something went wrong", isPresented: .init(
            get: { session.errorMessage != nil },
            set: { if !$0 { session.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.errorMessage ?? "")
        }
    }

    /// The video and everything drawn over it.
    private func stage(docked: Bool, insets: EdgeInsets) -> some View {
        ZStack {
            PlayerVideoView(engine: session.coordinator.engine)
            if session.coordinator.engine?.avPlayerEngine?.isExternalPlaybackActive == true {
                AirPlayPlaceholder(deviceName: airPlay.deviceName, compact: docked)
            }
            gestureLayer(docked: docked)

            if chrome.controlsVisible {
                // Keeps the bars readable over bright video.
                scrim(docked: docked)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                PlayerControlsView(session: session, compact: docked, onClose: close,
                                   onToggleFullScreen: canToggleFullScreen ? { toggleFullScreen(docked: docked) } : nil)
                    .padding(insets)
                    .transition(.opacity)
            }

            if case .failed(let message) = session.coordinator.state {
                PlaybackFailureView(
                    message: message,
                    compact: docked,
                    onRetry: { session.coordinator.retry() },
                    onNextChannel: session.zapList.neighbor(1) == nil ? nil : { session.zap(by: 1) }
                )
                .foregroundStyle(.white)
            }

            if chrome.controlsVisible, !docked, session.context != nil {
                ChannelsTab()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, insets.trailing + 12)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if chrome.controlsVisible, session.coordinator.engine is FFmpegPlayerEngine, let device = airPlay.deviceName {
                AirPlaySoundOnlyNotice(deviceName: device)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(insets)
                    // Below the top bar in full screen; over the top of the video when docked.
                    .padding(.top, docked ? 8 : 76)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            UpNextPrompt(session: session, compact: docked)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(insets)
                // Above the bottom bar.
                .padding(.bottom, docked ? 52 : 76)
                .padding(.trailing, docked ? 8 : 16)
                .animation(.default, value: session.isUpNextDismissed)

            if let hud = chrome.hudMessage {
                PlayerHUD(message: hud)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            if chrome.showsChannelBanner {
                ChannelBanner(session: session)
                    .scaleEffect(docked ? 0.85 : 1, anchor: .topLeading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(insets)
                    // Below the top bar when it's showing.
                    .padding(.top, !docked && chrome.controlsVisible ? 76 : 0)
                    .padding(docked ? 8 : 16)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            if chrome.showsChannelPanel, !docked {
                ChannelPanel(session: session)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(insets)
                    .padding(12)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .clipped()
    }

    /// Tap to show or hide the controls, swipe up or down to change channel, swipe left for the channel list
    /// (full screen), pinch to fill or fit.
    private func gestureLayer(docked: Bool) -> some View {
        Color.clear
            .contentShape(.rect)
            .onTapGesture { chrome.tappedVideo() }
            .gesture(
                DragGesture(minimumDistance: 24).onEnded { value in
                    let dx = value.translation.width, dy = value.translation.height
                    guard !chrome.isLocked else { return }
                    if abs(dy) > 60, abs(dy) > abs(dx) * 1.5 {
                        session.zap(by: dy < 0 ? 1 : -1)
                    } else if !docked, session.context != nil, dx < -60, abs(dx) > abs(dy) * 1.5 {
                        chrome.openChannelPanel()
                    }
                }
            )
            .simultaneousGesture(
                MagnifyGesture().onEnded { value in
                    guard !chrome.isLocked, let engine = session.coordinator.engine else { return }
                    let gravity: VideoGravity = value.magnification > 1 ? .fill : .fit
                    guard gravity != engine.videoGravity else { return }
                    engine.videoGravity = gravity
                    chrome.showHUD(gravity.title)
                }
            )
            .accessibilityHidden(true)
    }

    @ViewBuilder private func scrim(docked: Bool) -> some View {
        if docked {
            Color.black.opacity(0.3)
        } else {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 140)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 140)
            }
        }
    }

    private func dockedChannels(bottomInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack {
                NowPlayingTitle(session: session, fallback: session.context?.title,
                                logoSize: CGSize(width: 56, height: 40))
                Spacer(minLength: 8)
                if let position = session.zapList.positionLabel {
                    Text(position)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            if session.context != nil {
                ChannelZapList(session: session)
                    .contentMargins(.bottom, bottomInset, for: .scrollContent)
            } else if let plot = session.movie?.plot ?? session.episode?.plot ?? session.series?.plot {
                ScrollView {
                    Text(plot)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .contentMargins(.bottom, bottomInset, for: .scrollContent)
            } else {
                Spacer()
            }
        }
        .disabled(chrome.isLocked)
    }

    /// UI tests can't use AirPlay, so they turn the bridge on with a launch argument.
    private static let alwaysBridges = ProcessInfo.processInfo.arguments.contains("--prefer-bridge")

    private func close() {
        dismiss()
    }

    /// iPhone only: on iPad the system decides the window's shape.
    private var canToggleFullScreen: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    private func toggleFullScreen(docked: Bool) {
        UIApplication.shared.activeWindowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: docked ? .landscapeRight : .portrait)) { _ in }
    }
}
