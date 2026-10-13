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
    let resolver: PlaybackResolver
    /// Set when the on-disk database couldn't be opened and the app fell back to memory.
    let startupError: String?

    private(set) var sources: [Source] = []
    private(set) var hasLoadedSources = false
    /// Sources with a sync in progress, and how far along each is.
    private(set) var syncPhases: [Int64: SyncPhase] = [:]
    var nowPlaying: PlaybackItem?
    /// A user-facing error to show in an alert.
    var alertMessage: String?

    var activeSourceID: Int64? {
        didSet { UserDefaults.standard.set(activeSourceID, forKey: Self.activeSourceKey) }
    }

    var activeSource: Source? {
        sources.first { $0.id == activeSourceID } ?? sources.first
    }

    private static let activeSourceKey = "activeSourceID"
    private static let staleInterval: TimeInterval = 24 * 60 * 60

    init(database: AppDatabase, credentials: any CredentialStore, playlistDirectory: URL, startupError: String? = nil) {
        self.database = database
        self.credentials = credentials
        self.syncService = SourceSyncService(database: database, credentials: credentials, playlistDirectory: playlistDirectory)
        self.resolver = PlaybackResolver(credentials: credentials)
        self.startupError = startupError
        self.activeSourceID = (UserDefaults.standard.object(forKey: Self.activeSourceKey) as? NSNumber)?.int64Value
    }

    /// The model the app runs with, backed by Application Support and the keychain.
    static func live() -> AppModel {
        let support = URL.applicationSupportDirectory.appending(component: "RpTv")
        let playlists = support.appending(component: "Playlists")
        try? FileManager.default.createDirectory(at: playlists, withIntermediateDirectories: true)
        if ProcessInfo.processInfo.arguments.contains("--uitesting") {
            // UI tests start from a clean slate every launch.
            UserDefaults.standard.removeObject(forKey: activeSourceKey)
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
        var trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("://") { trimmed = "http://" + trimmed }
        guard let parsed = URL(string: trimmed), parsed.host() != nil else { throw SyncError.invalidLocation }
        let source = Source(
            name: name.nonEmptyTrimmed ?? parsed.host() ?? "Playlist",
            kind: .m3u,
            location: parsed.absoluteString,
            epgURL: epgURL?.nonEmptyTrimmed,
            userAgent: userAgent?.nonEmptyTrimmed
        )
        try await addAndSync(source)
    }

    func addPlaylistFile(name: String, fileURL: URL) async throws {
        let accessing = fileURL.startAccessingSecurityScopedResource()
        defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }
        let fileName = "\(UUID().uuidString).m3u"
        try FileManager.default.copyItem(at: fileURL, to: syncService.playlistDirectory.appending(component: fileName))
        let source = Source(
            name: name.nonEmptyTrimmed ?? fileURL.deletingPathExtension().lastPathComponent,
            kind: .m3u,
            location: fileName,
            isLocalFile: true
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

    /// Saves a source and runs its first sync. If the sync fails, the source is removed again.
    private func addAndSync(_ source: Source) async throws {
        let saved = try await database.insertSource(source)
        do {
            try await sync(saved)
            activeSourceID = saved.id
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

    /// Refreshes sources whose catalog is older than a day.
    func refreshStaleSources() async {
        for source in sources where (source.lastSyncedAt ?? .distantPast).timeIntervalSinceNow < -Self.staleInterval {
            try? await sync(source)
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

    // MARK: - Playback

    func play(_ channel: Channel) {
        guard let source = sources.first(where: { $0.id == channel.sourceID }) else { return }
        do {
            nowPlaying = try resolver.item(for: channel, in: source)
        } catch {
            alertMessage = error.localizedDescription
        }
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
