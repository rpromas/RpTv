// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Sources written out as JSON, to move them to another device. Passwords are never included: importing asks
/// for each one. Imported playlist files are left out, since only their copy on this device exists.
public struct SourceExport: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public struct Entry: Codable, Sendable, Hashable {
        public var name: String
        public var kind: Source.Kind
        /// The playlist URL, or the Xtream server.
        public var location: String
        public var username: String?
        public var epgURL: String?
        public var userAgent: String?
        public var referrer: String?
        public var enginePreference: EnginePreference?

        public init(_ source: Source) {
            name = source.name
            kind = source.kind
            location = source.location
            username = source.username
            epgURL = source.epgURL
            userAgent = source.userAgent
            referrer = source.referrer
            enginePreference = source.enginePreference
        }

        /// Whether importing it needs a password.
        public var needsPassword: Bool { kind == .xtream }

        /// A new source with these settings. Xtream accounts need the key their password is stored under.
        public func makeSource(credentialKey: String? = nil) -> Source {
            Source(name: name, kind: kind, location: location, username: username, credentialKey: credentialKey,
                   epgURL: epgURL, userAgent: userAgent, referrer: referrer, enginePreference: enginePreference ?? .automatic)
        }
    }

    public var version: Int
    public var sources: [Entry]

    /// The sources to export. Imported playlist files are skipped.
    public init(sources: [Source]) {
        version = Self.currentVersion
        self.sources = sources.filter { !$0.isLocalFile }.map(Entry.init)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> SourceExport {
        let export: SourceExport
        do {
            export = try JSONDecoder().decode(SourceExport.self, from: data)
        } catch {
            throw SourceExportError.unreadable
        }
        guard export.version <= currentVersion else { throw SourceExportError.newerVersion }
        return export
    }
}

public enum SourceExportError: LocalizedError, Equatable {
    case unreadable
    case newerVersion

    public var errorDescription: String? {
        switch self {
        case .unreadable: "The file isn't an RpTv source export."
        case .newerVersion: "The file comes from a newer version of RpTv. Update the app to import it."
        }
    }
}
