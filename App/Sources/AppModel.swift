// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation
import RpTvKit

/// App-wide state: the sources, sync status, and what's playing.
@MainActor
@Observable
final class AppModel {
    let database: AppDatabase
    let credentials: any CredentialStore
    let syncService: SourceSyncService
    let epgSyncService: EPGSyncService
    let settings: AppSettings
    /// The parental-control PIN, and whether locked categories are open right now.
    let parental: ParentalControls
    /// Programme reminders from the guide.
    let reminders = Reminders()
    /// Set when the on-disk database couldn't be opened and the app fell back to memory.
    let startupError: String?

    private(set) var sources: [Source] = []
    private(set) var hasLoadedSources = false
    /// Sources with a sync in progress, and how far along each is.
    private(set) var syncPhases: [Int64: SyncPhase] = [:]
    /// Sources whose TV guide is being downloaded.
    private(set) var guideSyncing: Set<Int64> = []
    /// Every favorite of every source, for marking starred items wherever they appear.
    private(set) var favorites: Set<ItemKey> = []
    /// The player on screen, if any.
    var playerSession: PlayerSession?
    /// A user-facing error to show in an alert.
    var alertMessage: String?
    /// Whether the Add Source sheet is up. `RootView` presents it, so it can blur the whole app behind it on Mac.
    var isAddingSource = false
    /// A request for the parental PIN, shown by `RootView`.
    var pinRequest: PINRequest?

    var activeSourceID: Int64? {
        didSet { UserDefaults.standard.set(activeSourceID, forKey: Self.activeSourceKey) }
    }

    var activeSource: Source? {
        sources.first { $0.id == activeSourceID } ?? sources.first
    }

    /// Builds what the player plays, with the user's playback settings.
    var resolver: PlaybackResolver {
        PlaybackResolver(credentials: credentials, preferences: settings.playback)
    }

    /// Whether lists, search, favorites and recents may show what's in locked categories right now.
    var includesLocked: Bool { !parental.isRestricted }

    private static let activeSourceKey = "activeSourceID"
    /// The setting that reopens the last channel at launch. Off unless the user turns it on.
    static let resumeLastChannelKey = "resumeLastChannel"

    init(database: AppDatabase, credentials: any CredentialStore, playlistDirectory: URL, settings: AppSettings = AppSettings(),
         startupError: String? = nil) {
        self.database = database
        self.credentials = credentials
        self.syncService = SourceSyncService(database: database, credentials: credentials, playlistDirectory: playlistDirectory)
        self.epgSyncService = EPGSyncService(database: database, credentials: credentials)
        self.settings = settings
        self.parental = ParentalControls(store: credentials)
        self.startupError = startupError
        self.activeSourceID = (UserDefaults.standard.object(forKey: Self.activeSourceKey) as? NSNumber)?.int64Value
        reminders.onOpen = { [weak self] sourceID, stableKey in
            Task { await self?.openChannel(sourceID: sourceID, stableKey: stableKey) }
        }
    }

    /// The model the app runs with, backed by Application Support and the keychain.
    static func live() -> AppModel {
        let support = URL.applicationSupportDirectory.appending(component: "RpTv")
        let playlists = support.appending(component: "Playlists")
        try? FileManager.default.createDirectory(at: playlists, withIntermediateDirectories: true)
        if ProcessInfo.processInfo.arguments.contains("--uitesting") {
            // UI tests start from a clean slate every launch.
            UserDefaults.standard.removeObject(forKey: activeSourceKey)
            UserDefaults.standard.removeObject(forKey: resumeLastChannelKey)
            AppSettings.reset()
            return AppModel(database: try! AppDatabase.inMemory(), credentials: InMemoryCredentialStore(),
                            playlistDirectory: playlists)
        }
        do {
            let database = try AppDatabase.open(at: support.appending(component: "rptv.sqlite"))
            return AppModel(database: database, credentials: KeychainCredentialStore(), playlistDirectory: playlists)
        } catch {
            return AppModel(database: try! AppDatabase.inMemory(), credentials: KeychainCredentialStore(),
                            playlistDirectory: playlists, startupError: error.localizedDescription)
        }
    }

    // MARK: - Sources

    /// Keeps ``sources`` in sync with the database. Runs for the app's lifetime.
    func observeSources() async {
        do {
            for try await sources in database.observeSources() {
                self.sources = sources
                hasLoadedSources = true
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func addPlaylist(name: String, url: String, epgURL: String?, userAgent: String?) async throws {
        let parsed = try Self.playlistURL(url)
        let source = Source(
            name: name.nonEmptyTrimmed ?? parsed.host() ?? "Playlist",
            kind: .m3u,
            location: parsed.absoluteString,
            epgURL: epgURL?.nonEmptyTrimmed,
            userAgent: userAgent?.nonEmptyTrimmed
        )
        try await addAndSync(source)
    }

    func addPlaylistFile(name: String, fileURL: URL, epgURL: String?) async throws {
        let accessing = fileURL.startAccessingSecurityScopedResource()
        defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }
        let fileName = "\(UUID().uuidString).m3u"
        try FileManager.default.copyItem(at: fileURL, to: syncService.playlistDirectory.appending(component: fileName))
        let source = Source(
            name: name.nonEmptyTrimmed ?? fileURL.deletingPathExtension().lastPathComponent,
            kind: .m3u,
            location: fileName,
            isLocalFile: true,
            epgURL: epgURL?.nonEmptyTrimmed
        )
        do {
            try await addAndSync(source)
        } catch {
            try? FileManager.default.removeItem(at: syncService.playlistDirectory.appending(component: fileName))
            throw error
        }
    }

    func addXtream(name: String, server: String, username: String, password: String, userAgent: String?) async throws {
        guard let credentials = XtreamCredentials(server: server, username: username, password: password) else {
            throw XtreamError.invalidServer
        }
        let headers = userAgent?.nonEmptyTrimmed.map { ["User-Agent": $0] } ?? [:]
        // Check the login before saving anything.
        _ = try await XtreamClient(credentials: credentials, headers: headers).authenticate()

        let key = UUID().uuidString
        try self.credentials.setPassword(password, for: key)
        let source = Source(
            name: name.nonEmptyTrimmed ?? credentials.server.host() ?? "Xtream",
            kind: .xtream,
            location: credentials.server.absoluteString,
            username: username,
            credentialKey: key,
            userAgent: userAgent?.nonEmptyTrimmed
        )
        do {
            try await addAndSync(source)
        } catch {
            try? self.credentials.deletePassword(for: key)
            throw error
        }
    }

    /// The playlist address the user typed, with `http://` added when it has no scheme.
    private static func playlistURL(_ text: String) throws -> URL {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("://") { trimmed = "http://" + trimmed }
        guard let parsed = URL(string: trimmed), parsed.host() != nil else { throw SyncError.invalidLocation }
        return parsed
    }

    /// Saves a source and runs its first sync. If the sync fails, the source is removed again.
    private func addAndSync(_ source: Source) async throws {
        let saved = try await database.insertSource(source)
        do {
            try await sync(saved)
            activeSourceID = saved.id
            refreshGuideInBackground(saved, force: true)
        } catch {
            try? await database.deleteSource(id: saved.id!)
            throw error
        }
    }

    func sync(_ source: Source) async throws {
        guard let id = source.id, syncPhases[id] == nil else { return }
        syncPhases[id] = .connecting
        defer { syncPhases[id] = nil }
        try await syncService.sync(source) { phase in
            Task { @MainActor [weak self] in
                // Ignore late updates that arrive after the sync finished.
                if self?.syncPhases[id] != nil { self?.syncPhases[id] = phase }
            }
        }
    }

    /// Refreshes sources whose catalog is older than the interval set in Settings.
    func refreshStaleSources() async {
        guard let interval = settings.catalogRefreshInterval else { return }
        for source in sources where (source.lastSyncedAt ?? .distantPast).timeIntervalSinceNow < -interval {
            try? await sync(source)
        }
    }

    /// Saves the user's changes to a source. When the address, login or headers change, the source is synced
    /// again to check them, and the changes are undone if that fails.
    func save(_ edit: SourceEdit, to sourceID: Int64) async throws {
        guard syncPhases[sourceID] == nil else { throw SourceEditError.syncInProgress }
        guard let original = try await database.source(id: sourceID) else { return }
        var updated = original
        updated.name = edit.name.nonEmptyTrimmed ?? original.name
        updated.epgURL = edit.epgURL.nonEmptyTrimmed
        updated.userAgent = edit.userAgent.nonEmptyTrimmed
        updated.referrer = edit.referrer.nonEmptyTrimmed
        updated.enginePreference = edit.enginePreference
        // A new password goes under a new key, so the old one still works if the check fails.
        var newKey: String?
        switch original.kind {
        case .xtream:
            guard let server = XtreamCredentials.normalizeServer(edit.location) else { throw XtreamError.invalidServer }
            updated.location = server.absoluteString
            updated.username = edit.username.trimmingCharacters(in: .whitespaces)
            if !edit.password.isEmpty {
                let key = UUID().uuidString
                try credentials.setPassword(edit.password, for: key)
                updated.credentialKey = key
                newKey = key
            }
        case .m3u:
            if !original.isLocalFile { updated.location = try Self.playlistURL(edit.location).absoluteString }
        }
        if updated.epgURL != original.epgURL { updated.lastEPGSyncError = nil }

        let needsSync = updated.location != original.location || updated.username != original.username || newKey != nil
            || updated.userAgent != original.userAgent || updated.referrer != original.referrer
        do {
            try await database.updateSource(updated)
            if needsSync { try await sync(updated) }
        } catch {
            try? await database.updateSource(original)
            if let newKey { try? credentials.deletePassword(for: newKey) }
            throw error
        }
        if newKey != nil, let oldKey = original.credentialKey { try? credentials.deletePassword(for: oldKey) }
        if needsSync || updated.epgURL != original.epgURL {
            refreshGuideInBackground(updated, force: true)
        }
    }

    /// The Xtream account's status, straight from the server.
    func accountStatus(of source: Source) async throws -> XtreamAccount {
        try await syncService.accountStatus(of: source)
    }

    // MARK: - Export and import

    /// The sources as JSON, without passwords or imported playlist files.
    func exportSources() throws -> Data {
        try SourceExport(sources: sources).encoded()
    }

    /// Whether a source with the same address and login is already added.
    func hasSource(like entry: SourceExport.Entry) -> Bool {
        sources.contains { $0.kind == entry.kind && $0.location == entry.location && $0.username == entry.username }
    }

    /// Adds an exported source and syncs it. Xtream accounts need their password.
    func importSource(_ entry: SourceExport.Entry, password: String) async throws {
        var key: String?
        if entry.needsPassword {
            guard !password.isEmpty else { throw SyncError.missingPassword }
            key = UUID().uuidString
            try credentials.setPassword(password, for: key!)
        }
        do {
            try await addAndSync(entry.makeSource(credentialKey: key))
        } catch {
            if let key { try? credentials.deletePassword(for: key) }
            throw error
        }
    }

    // MARK: - TV guide

    /// Downloads a source's TV guide unless it is already being downloaded. Without `force`, only when
    /// the guide is over 12 hours old. Failures are recorded on the source rather than shown in an alert,
    /// since this runs in the background.
    func syncGuide(sourceID: Int64, force: Bool) async {
        guard guideSyncing.insert(sourceID).inserted else { return }
        defer { guideSyncing.remove(sourceID) }
        // Re-read the source: a catalog sync may just have found its guide URL.
        guard let source = try? await database.source(id: sourceID), EPGSyncService.hasGuide(source),
              force || EPGSyncService.isStale(source, interval: settings.guideRefreshInterval) else { return }
        try? await epgSyncService.sync(source)
    }

    /// Starts a guide refresh without waiting for it, so it never holds up a catalog sync.
    func refreshGuideInBackground(_ source: Source, force: Bool) {
        guard let id = source.id else { return }
        Task { await syncGuide(sourceID: id, force: force) }
    }

    /// Refreshes guides older than the interval set in Settings, one source at a time.
    func refreshStaleGuides() async {
        for id in sources.compactMap(\.id) {
            await syncGuide(sourceID: id, force: false)
        }
    }

    /// Deletes every source's TV guide. They download again on the next refresh.
    func clearGuides() async {
        do {
            try await database.clearGuides()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func delete(_ source: Source) async {
        guard let id = source.id else { return }
        do {
            try await database.deleteSource(id: id)
            if let key = source.credentialKey { try? credentials.deletePassword(for: key) }
            if source.isLocalFile {
                try? FileManager.default.removeItem(at: syncService.playlistDirectory.appending(component: source.location))
            }
            if activeSourceID == id { activeSourceID = nil }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    // MARK: - Parental controls

    /// Asks for the parental PIN (or Face ID), unless no PIN is set. A right answer also opens locked
    /// categories for the session.
    func authorize(reason: String) async -> Bool {
        guard parental.hasPIN else { return true }
        pinRequest?.finish(false)
        return await withCheckedContinuation { continuation in
            pinRequest = PINRequest(reason: reason, continuation: continuation)
        }
    }

    /// Opens locked categories for the session, asking for the PIN unless they're open already.
    @discardableResult
    func unlockLockedContent() async -> Bool {
        guard parental.isRestricted else { return true }
        return await authorize(reason: "Enter your PIN to open locked categories.")
    }

    /// Removes the PIN and unlocks every category. Needs the session unlocked.
    func turnOffParentalControls() async {
        do {
            try parental.removePIN()
            try await database.unlockAllCategories()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// Runs a change to the database, reporting a failure in an alert.
    func perform(_ change: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await change()
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Favorites

    /// Keeps ``favorites`` in sync with the database. Runs for the app's lifetime.
    func observeFavorites() async {
        do {
            for try await favorites in database.observeFavoriteKeys() {
                self.favorites = favorites
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func isFavorite(_ item: ItemKey) -> Bool {
        favorites.contains(item)
    }

    func toggleFavorite(_ item: ItemKey) {
        Task {
            do {
                try await database.toggleFavorite(item)
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    /// Moves a source's favorite channels into the order of `channels`.
    func reorderFavorites(_ channels: [Channel], sourceID: Int64) async {
        do {
            try await database.reorderFavorites(sourceID: sourceID, kind: .channel, stableKeys: channels.map(\.stableKey))
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    // MARK: - Playback

    /// Opens the player on `channel`. `context` is the list it was picked from, which the player zaps through.
    /// With `catchup`, plays that programme from the channel's archive instead of the live stream.
    func play(_ channel: Channel, in context: ChannelListContext?, catchup: Programme? = nil) {
        guard let source = sources.first(where: { $0.id == channel.sourceID }) else { return }
        do {
            playerSession = try PlayerSession(channel: channel, source: source, context: context, catchup: catchup,
                                              includesLocked: includesLocked, database: database, resolver: resolver)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// Opens the player on a movie.
    func play(_ movie: Movie) {
        guard let source = sources.first(where: { $0.id == movie.sourceID }) else { return }
        do {
            playerSession = try PlayerSession(movie: movie, source: source, database: database, resolver: resolver)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// Fetches a movie's details from its provider when they're missing or over a week old.
    func refreshDetails(of movie: Movie) async throws {
        guard let source = sources.first(where: { $0.id == movie.sourceID }) else { return }
        try await syncService.refreshDetails(of: movie, in: source)
    }

    /// Plays a channel a reminder points at, zapping through all of its source's channels.
    private func openChannel(sourceID: Int64, stableKey: String) async {
        guard let channel = try? await database.channel(sourceID: sourceID, stableKey: stableKey) else { return }
        playerSession = nil
        play(channel, in: .allChannels(of: sourceID))
    }

    /// Reopens the channel played last, if the user turned that on in Settings. Call once sources have loaded.
    func resumeLastChannelIfEnabled() async {
        guard UserDefaults.standard.bool(forKey: Self.resumeLastChannelKey), playerSession == nil,
              let channel = try? await database.lastPlayedChannel(includingLocked: includesLocked), playerSession == nil else { return }
        play(channel, in: .allChannels(of: channel.sourceID))
    }
}

extension ChannelListContext {
    static func allChannels(of sourceID: Int64) -> ChannelListContext {
        ChannelListContext(sourceID: sourceID, list: .all, title: "All Channels")
    }
}

/// What the user can change about a source, as typed in the edit form.
struct SourceEdit {
    var name: String
    /// The playlist URL, or the Xtream server.
    var location: String
    var username: String
    /// Empty keeps the saved password.
    var password = ""
    var epgURL: String
    var userAgent: String
    var referrer: String
    var enginePreference: EnginePreference

    init(_ source: Source) {
        name = source.name
        location = source.location
        username = source.username ?? ""
        epgURL = source.epgURL ?? ""
        userAgent = source.userAgent ?? ""
        referrer = source.referrer ?? ""
        enginePreference = source.enginePreference
    }
}

enum SourceEditError: LocalizedError {
    case syncInProgress

    var errorDescription: String? {
        switch self {
        case .syncInProgress: "This source is updating. Try again when it's done."
        }
    }
}

/// A request for the parental PIN. Answered once: by the PIN sheet, or with `false` when the sheet goes away.
@MainActor
final class PINRequest: Identifiable {
    let reason: String
    private var continuation: CheckedContinuation<Bool, Never>?

    init(reason: String, continuation: CheckedContinuation<Bool, Never>) {
        self.reason = reason
        self.continuation = continuation
    }

    func finish(_ granted: Bool) {
        continuation?.resume(returning: granted)
        continuation = nil
    }
}

extension String {
    /// The string without surrounding whitespace, or `nil` when nothing is left.
    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension AppModel {
    /// An in-memory model for SwiftUI previews.
    static func preview() -> AppModel {
        AppModel(database: try! AppDatabase.inMemory(), credentials: InMemoryCredentialStore(),
                 playlistDirectory: URL.temporaryDirectory)
    }
}
