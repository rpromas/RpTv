// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import GRDB
import Testing
@testable import RpTvKit

/// The FFmpeg player replaced VLC: choices saved as "vlc" now mean the FFmpeg player.
struct EngineRenameTests {
    @Test func readsTheOldName() {
        #expect(EnginePreference(rawValue: "vlc") == .ffmpeg)
        #expect(PlayerEngineKind(rawValue: "vlc") == .ffmpeg)
        #expect(EnginePreference.ffmpeg.rawValue == "ffmpeg")
    }

    @Test func codesAsAString() throws {
        #expect(String(decoding: try JSONEncoder().encode([EnginePreference.ffmpeg]), as: UTF8.self) == #"["ffmpeg"]"#)
        #expect(try JSONDecoder().decode([EnginePreference].self, from: Data(#"["vlc", "native"]"#.utf8)) == [.ffmpeg, .native])
    }

    @Test func remembersOldEngines() throws {
        let defaults = try #require(UserDefaults(suiteName: "EngineRenameTests.\(UUID())"))
        defaults.set(["item": "vlc"], forKey: "workingEngineByItem")
        #expect(EngineMemory(defaults: defaults).engine(for: "item") == .ffmpeg)
    }

    @Test func migratesSources() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v8")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO source (name, kind, location, createdAt, enginePreference)
                VALUES ('A', 'm3u', 'http://example.com', 0, 'vlc')
                """)
        }
        let database = try AppDatabase(queue)
        let stored = try database.reader.read { try String.fetchOne($0, sql: "SELECT enginePreference FROM source") }
        #expect(stored == "ffmpeg")
    }
}
