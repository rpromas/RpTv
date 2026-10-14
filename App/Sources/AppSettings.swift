// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation
import RpTvKit
import SwiftUI

/// The user's app-wide settings, kept in `UserDefaults`.
@MainActor
@Observable
final class AppSettings {
    enum Appearance: String, CaseIterable {
        case system
        case light
        case dark

        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    /// The engine for sources left on Automatic.
    var defaultEngine: EnginePreference { didSet { defaults.set(defaultEngine.rawValue, forKey: Keys.defaultEngine) } }
    /// Seconds of a live stream to buffer before playing. 0 leaves it to the engine.
    var liveBufferSeconds: Int { didSet { defaults.set(liveBufferSeconds, forKey: Keys.liveBuffer) } }
    /// How old a catalog gets before it's refreshed at launch. 0 means only by hand.
    var catalogRefreshHours: Int { didSet { defaults.set(catalogRefreshHours, forKey: Keys.catalogRefresh) } }
    /// How old a TV guide gets before it's refreshed at launch.
    var guideRefreshHours: Int { didSet { defaults.set(guideRefreshHours, forKey: Keys.guideRefresh) } }
    /// Two-letter language code, or `nil` for the stream's default track.
    var audioLanguage: String? { didSet { defaults.set(audioLanguage, forKey: Keys.audioLanguage) } }
    /// Two-letter language code, or `nil` for no subtitles.
    var subtitleLanguage: String? { didSet { defaults.set(subtitleLanguage, forKey: Keys.subtitleLanguage) } }
    var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) } }

    @ObservationIgnored private let defaults: UserDefaults

    private enum Keys {
        static let defaultEngine = "defaultEngine"
        static let liveBuffer = "liveBufferSeconds"
        static let catalogRefresh = "catalogRefreshHours"
        static let guideRefresh = "guideRefreshHours"
        static let audioLanguage = "audioLanguage"
        static let subtitleLanguage = "subtitleLanguage"
        static let appearance = "appearance"
        static let all = [defaultEngine, liveBuffer, catalogRefresh, guideRefresh, audioLanguage, subtitleLanguage, appearance]
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaultEngine = defaults.string(forKey: Keys.defaultEngine).flatMap(EnginePreference.init(rawValue:)) ?? .automatic
        liveBufferSeconds = defaults.integer(forKey: Keys.liveBuffer)
        catalogRefreshHours = defaults.object(forKey: Keys.catalogRefresh) as? Int ?? 24
        guideRefreshHours = defaults.object(forKey: Keys.guideRefresh) as? Int ?? Int(EPGSyncService.staleInterval / 3600)
        audioLanguage = defaults.string(forKey: Keys.audioLanguage)
        subtitleLanguage = defaults.string(forKey: Keys.subtitleLanguage)
        appearance = defaults.string(forKey: Keys.appearance).flatMap(Appearance.init(rawValue:)) ?? .system
    }

    /// Forgets every setting, for UI tests that start from a clean slate.
    static func reset(_ defaults: UserDefaults = .standard) {
        for key in Keys.all { defaults.removeObject(forKey: key) }
    }

    var playback: PlaybackPreferences {
        PlaybackPreferences(engine: defaultEngine, liveBuffer: liveBufferSeconds > 0 ? TimeInterval(liveBufferSeconds) : nil,
                            audioLanguage: audioLanguage, subtitleLanguage: subtitleLanguage)
    }

    /// `nil` when catalogs are only refreshed by hand.
    var catalogRefreshInterval: TimeInterval? {
        catalogRefreshHours > 0 ? TimeInterval(catalogRefreshHours) * 3600 : nil
    }

    var guideRefreshInterval: TimeInterval {
        TimeInterval(max(guideRefreshHours, 1)) * 3600
    }
}
