// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Observation
import SwiftUI

/// What the player shows on top of the video, and when it fades away.
@MainActor
@Observable
final class PlayerChrome {
    private(set) var controlsVisible = true
    private(set) var isLocked = false
    /// While locked, the one button that unlocks, shown briefly after a tap.
    private(set) var showsUnlockButton = false
    private(set) var showsChannelPanel = false
    private(set) var showsChannelBanner = false
    /// A short message in the middle of the video, like the new aspect mode.
    private(set) var hudMessage: String?

    /// Playback isn't running (loading, paused, failed), so the controls stay up.
    var holdsControls = false {
        didSet { scheduleHide() }
    }

    var isScrubbing = false {
        didSet { interacted() }
    }

    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var unlockButtonTask: Task<Void, Never>?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var hudTask: Task<Void, Never>?

    private static let autoHideDelay = Duration.seconds(4)
    /// UI tests can't keep up with controls that fade on a timer, so they stay until tapped away.
    private static let autoHides = !ProcessInfo.processInfo.arguments.contains("--uitesting")
    private static let fade = Animation.easeOut(duration: 0.25)

    /// Call on any use of a control: shows the controls and restarts the auto-hide countdown.
    func interacted() {
        guard !isLocked else { return }
        if !controlsVisible { withAnimation(Self.fade) { controlsVisible = true } }
        scheduleHide()
    }

    func tappedVideo() {
        if isLocked {
            flashUnlockButton()
        } else if showsChannelPanel {
            closeChannelPanel()
        } else if controlsVisible {
            hideTask?.cancel()
            withAnimation(Self.fade) { controlsVisible = false }
        } else {
            interacted()
        }
    }

    func lock() {
        hideTask?.cancel()
        withAnimation(Self.fade) {
            isLocked = true
            controlsVisible = false
            showsChannelPanel = false
        }
        OrientationLock.lock()
        flashUnlockButton()
    }

    func unlock() {
        unlockButtonTask?.cancel()
        withAnimation(Self.fade) {
            isLocked = false
            showsUnlockButton = false
        }
        OrientationLock.unlock()
        interacted()
    }

    func openChannelPanel() {
        hideTask?.cancel()
        withAnimation(.snappy) {
            controlsVisible = false
            showsChannelPanel = true
        }
    }

    func closeChannelPanel() {
        withAnimation(.snappy) { showsChannelPanel = false }
        interacted()
    }

    func showChannelBanner() {
        withAnimation(Self.fade) { showsChannelBanner = true }
        bannerTask?.cancel()
        bannerTask = after(.seconds(3)) { $0.showsChannelBanner = false }
    }

    func showHUD(_ message: String) {
        withAnimation(Self.fade) { hudMessage = message }
        hudTask?.cancel()
        hudTask = after(.seconds(1.5)) { $0.hudMessage = nil }
    }

    private func flashUnlockButton() {
        withAnimation(Self.fade) { showsUnlockButton = true }
        unlockButtonTask?.cancel()
        unlockButtonTask = after(.seconds(2)) { $0.showsUnlockButton = false }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard Self.autoHides, controlsVisible, !holdsControls, !isScrubbing, !isLocked else { return }
        hideTask = after(Self.autoHideDelay) { $0.controlsVisible = false }
    }

    /// Runs `change` with the fade animation after `delay`, unless the returned task is cancelled first.
    private func after(_ delay: Duration, _ change: @escaping (PlayerChrome) -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            withAnimation(Self.fade) { change(self) }
        }
    }
}
