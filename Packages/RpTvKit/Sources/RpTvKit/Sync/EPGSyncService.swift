// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

public enum EPGSyncError: LocalizedError, Equatable {
    case invalidURL

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "The TV guide address isn't valid."
        }
    }
}

/// Downloads a source's XMLTV guide and stores it. Runs on its own, apart from the catalog sync.
public struct EPGSyncService: Sendable {
    /// By default, a guide older than this is refreshed on launch and on pull-to-refresh.
    public static let staleInterval: TimeInterval = 12 * 3600

    private let database: AppDatabase
    private let credentials: any CredentialStore
    private let downloader: any HTTPDownloader

    public init(database: AppDatabase, credentials: any CredentialStore, downloader: any HTTPDownloader = URLSession.shared) {
        self.database = database
        self.credentials = credentials
        self.downloader = downloader
    }

    /// Whether the source has a guide to download: an M3U source with a guide URL, or any Xtream account.
    public static func hasGuide(_ source: Source) -> Bool {
        source.kind == .xtream || source.epgURL?.isEmpty == false
    }

    public static func isStale(_ source: Source, now: Date = .now, interval: TimeInterval = staleInterval) -> Bool {
        guard let last = source.lastEPGSyncAt else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    /// The guide URL. For Xtream it is built from the keychain password here, and never stored.
    func guideURL(for source: Source) throws -> URL? {
        if let text = source.epgURL?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            guard let url = URL(string: text), url.scheme != nil else { throw EPGSyncError.invalidURL }
            return url
        }
        guard source.kind == .xtream else { return nil }
        return try SourceSyncService.xtreamCredentials(for: source, in: credentials).xmltvURL
    }

    /// Downloads and stores the source's guide, and returns how many programmes were kept.
    /// Returns 0 without touching anything when the source has no guide. Records the outcome on the source.
    @discardableResult
    @concurrent public func sync(_ source: Source, now: Date = .now) async throws -> Int {
        guard let sourceID = source.id else { preconditionFailure("Sync requires a saved source") }
        do {
            guard let url = try guideURL(for: source) else { return 0 }
            let (download, response) = try await downloader.download(URLRequest(url: url, headers: source.httpHeaders))
            defer { try? FileManager.default.removeItem(at: download) }
            guard (200..<300).contains(response.statusCode) else { throw HTTPError.status(response.statusCode) }

            let file = try GzipInflater.inflateIfNeeded(download)
            defer { if file != download { try? FileManager.default.removeItem(at: file) } }
            let count = try await database.importGuide(sourceID: sourceID, file: file, now: now)
            try await database.recordEPGSync(sourceID: sourceID, error: nil, at: now)
            return count
        } catch {
            if !(error is CancellationError) {
                try? await database.recordEPGSync(sourceID: sourceID, error: redacted(error.localizedDescription, for: source))
            }
            throw error
        }
    }

    /// Error messages are stored, so make sure an Xtream password never ends up in one.
    private func redacted(_ message: String, for source: Source) -> String {
        guard source.kind == .xtream, let key = source.credentialKey,
              let password = try? credentials.password(for: key), !password.isEmpty else { return message }
        return message.replacing(password, with: "•••")
    }
}
