// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation

/// Remembers which engine last played each item, so the next start skips an engine that doesn't work.
public struct EngineMemory {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "workingEngineByItem") {
        self.defaults = defaults
        self.key = key
    }

    public func engine(for itemID: String) -> PlayerEngineKind? {
        (defaults.dictionary(forKey: key)?[itemID] as? String).flatMap(PlayerEngineKind.init(rawValue:))
    }

    public func remember(_ kind: PlayerEngineKind, for itemID: String) {
        var engines = defaults.dictionary(forKey: key) ?? [:]
        engines[itemID] = kind.rawValue
        defaults.set(engines, forKey: key)
    }
}

/// Plays an item on the engine most likely to handle it, and moves to the fallback engine when the first one
/// fails, or doesn't start a live stream in time.
@MainActor
@Observable
public final class PlaybackCoordinator {
    /// The engine playing the current item. It changes when playback falls back to another engine.
    public private(set) var engine: (any PlayerEngine)?
    public private(set) var item: PlaybackItem?
    /// Set while AirPlay is on: streams that would play on VLC go through the bridge instead, so the TV gets video.
    public private(set) var prefersBridge = false

    public var state: PlaybackState { engine?.state ?? .idle }

    @ObservationIgnored private let makeEngine: @MainActor (PlayerEngineKind) -> any PlayerEngine
    @ObservationIgnored private let memory: EngineMemory
    @ObservationIgnored private let liveStartTimeout: Duration
    @ObservationIgnored private var attempted: Set<PlayerEngineKind> = []
    /// Set once the current engine reaches `.playing`. From then on a failure is shown instead of falling back.
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var stateTask: Task<Void, Never>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?

    public init(
        memory: EngineMemory = EngineMemory(),
        liveStartTimeout: Duration = .seconds(10),
        makeEngine: @escaping @MainActor (PlayerEngineKind) -> any PlayerEngine
    ) {
        self.memory = memory
        self.liveStartTimeout = liveStartTimeout
        self.makeEngine = makeEngine
    }

    isolated deinit {
        stateTask?.cancel()
        timeoutTask?.cancel()
        engine?.stop()
    }

    /// The engine to try first. A forced preference wins; otherwise the engine that last worked for this item,
    /// otherwise a guess from the URL. With `prefersBridge`, the bridge stands in for VLC.
    public static func initialEngine(for item: PlaybackItem, remembered: PlayerEngineKind?,
                                     prefersBridge: Bool = false) -> PlayerEngineKind {
        guard item.enginePreference == .automatic else {
            return EngineSelector.engine(for: item.url, preference: item.enginePreference)
        }
        let kind = remembered ?? EngineSelector.engine(for: item.url)
        if kind == .vlc || kind == .bridge { return prefersBridge ? .bridge : .vlc }
        return kind
    }

    public func play(_ item: PlaybackItem) {
        stop()
        self.item = item
        attempted = []
        let remembered = item.enginePreference == .automatic ? memory.engine(for: item.id) : nil
        start(Self.initialEngine(for: item, remembered: remembered, prefersBridge: prefersBridge))
    }

    /// Call when AirPlay turns on or off. Turning it on moves a stream playing on VLC to the bridge.
    public func setPrefersBridge(_ prefers: Bool) {
        guard prefers != prefersBridge else { return }
        prefersBridge = prefers
        if prefers, engine?.kind == .vlc, let item, item.enginePreference == .automatic {
            play(item)
        }
    }

    /// Starts the current item again from its first engine.
    public func retry() {
        if let item { play(item) }
    }

    public func stop() {
        stateTask?.cancel()
        timeoutTask?.cancel()
        engine?.stop()
        engine = nil
    }

    private func start(_ kind: PlayerEngineKind) {
        guard let item else { return }
        let engine = makeEngine(kind)
        attempted.insert(kind)
        hasStarted = false
        self.engine = engine
        engine.load(item)

        stateTask = Task { [weak self] in
            for await state in Observations({ engine.state }) {
                guard !Task.isCancelled else { return }
                self?.engine(engine, didChangeTo: state)
            }
        }
        if item.isLive, nextEngine != nil {
            // The bridge needs a few seconds of converted segments before AVPlayer can start.
            let timeout = kind == .bridge ? liveStartTimeout * 2 : liveStartTimeout
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, let self, engine === self.engine, !self.hasStarted else { return }
                self.fallBack()
            }
        }
    }

    private func engine(_ engine: any PlayerEngine, didChangeTo state: PlaybackState) {
        guard engine === self.engine, let item else { return }
        switch state {
        case .playing where !hasStarted:
            hasStarted = true
            timeoutTask?.cancel()
            // The bridge is VLC's stand-in for AirPlay: remember the stream as one AVPlayer can't open directly.
            if item.enginePreference == .automatic { memory.remember(engine.kind == .bridge ? .vlc : engine.kind, for: item.id) }
        case .failed where !hasStarted:
            fallBack()
        default:
            break
        }
    }

    /// The engine to retry with, if the user lets the app choose and one is left to try.
    private var nextEngine: PlayerEngineKind? {
        guard item?.enginePreference == .automatic, let current = engine?.kind,
              let next = EngineSelector.fallback(after: current, prefersBridge: prefersBridge),
              !attempted.contains(next) else { return nil }
        return next
    }

    private func fallBack() {
        guard let next = nextEngine else { return }
        stop()
        start(next)
    }
}
