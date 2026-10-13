// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
@testable import StreamBridge
import Testing

struct HLSServerTests {
    @Test func servesFilesUnderItsToken() async throws {
        let directory = URL.temporaryDirectory.appending(component: "HLSServerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("#EXTM3U\n".utf8).write(to: directory.appending(component: "index.m3u8"))

        let server = HLSServer(directory: directory)
        let port = try await server.start()
        defer { server.stop() }

        let url = server.playlistURL(host: "127.0.0.1", port: port)
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "application/vnd.apple.mpegurl")
        #expect(String(decoding: data, as: UTF8.self) == "#EXTM3U\n")

        let guessed = URL(string: "http://127.0.0.1:\(port)/not-the-token/index.m3u8")!
        let (_, missing) = try await URLSession.shared.data(from: guessed)
        #expect((missing as? HTTPURLResponse)?.statusCode == 404)
    }

    @Test func refusesPathsOutsideItsDirectory() {
        #expect(HLSServer.fileName(in: "/t/index.m3u8", token: "t") == "index.m3u8")
        #expect(HLSServer.fileName(in: "/t/../secret", token: "t") == nil)
        #expect(HLSServer.fileName(in: "/t/a/b.ts", token: "t") == nil)
        #expect(HLSServer.fileName(in: "/t/.hidden", token: "t") == nil)
        #expect(HLSServer.fileName(in: "/x/index.m3u8", token: "t") == nil)
    }
}
