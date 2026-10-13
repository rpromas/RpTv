// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AVFoundation
import SwiftUI

@main
struct RpTvApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = AppModel.live()

    init() {
        // Keep audio playing with the screen locked, in PiP, and with the silent switch on.
        // Long-form video routing lets AirPlay carry the picture to a TV, not only the sound.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}
