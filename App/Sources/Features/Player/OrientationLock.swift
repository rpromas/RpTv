// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import UIKit

/// Holds the screen in its current orientation while the player's controls are locked.
@MainActor
enum OrientationLock {
    /// What ``AppDelegate`` lets the app rotate to.
    private(set) static var allowed = UIInterfaceOrientationMask.all

    static func lock() {
        guard let scene = UIApplication.shared.activeWindowScene else { return }
        allowed = switch scene.effectiveGeometry.interfaceOrientation {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        default: .all
        }
        applyChange(in: scene)
    }

    static func unlock() {
        guard allowed != .all else { return }
        allowed = .all
        if let scene = UIApplication.shared.activeWindowScene { applyChange(in: scene) }
    }

    /// With the rotation lock on, iOS rotates only when an app asks, so closing the player in landscape (after its
    /// full screen button) would leave the app there. Turns it back to portrait unless the device is held sideways;
    /// with the rotation lock on, the device reports portrait however it's held.
    static func returnToPortraitIfNeeded() {
        guard UIDevice.current.userInterfaceIdiom == .phone,
              let scene = UIApplication.shared.activeWindowScene,
              scene.effectiveGeometry.interfaceOrientation.isLandscape,
              !UIDevice.current.orientation.isLandscape
        else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
    }

    /// Asks every controller on screen, including the presented player, to re-read the allowed orientations.
    private static func applyChange(in scene: UIWindowScene) {
        var controller = scene.keyWindow?.rootViewController
        while let current = controller {
            current.setNeedsUpdateOfSupportedInterfaceOrientations()
            controller = current.presentedViewController
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.allowed
    }
}

extension UIApplication {
    /// The scene the user is looking at.
    var activeWindowScene: UIWindowScene? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }
}
