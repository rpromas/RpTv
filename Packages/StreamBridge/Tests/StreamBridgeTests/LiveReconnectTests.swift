// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Network
@testable import StreamBridge
import Testing

/// A live source whose server drops the connection partway through, as IPTV proxies do.
struct LiveReconnectTests {
    /// Serves each connection the next chunk of a stream, then closes it. Once the chunks run out, it sends empty
    /// responses, like a channel that went off air.
    final class FlakyServer: @unchecked Sendable {
        private let chunks: [Data]
        private let queue = DispatchQueue(label: "FlakyServer")
        private var listener: NWListener?
        private var served = 0

        init(chunks: [Data]) {
            self.chunks = chunks
        }

        func start() async throws -> UInt16 {
            let listener = try NWListener(using: .tcp, on: .any)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
            for _ in 0..<100 where listener.port == nil || listener.port?.rawValue == 0 {
                try await Task.sleep(for: .milliseconds(10))
            }
            return listener.port!.rawValue
        }

        func stop() {
            listener?.cancel()
        }

        private func handle(_ connection: NWConnection) {
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [self] _, _, _, _ in
                let body = served < chunks.count ? chunks[served] : Data()
                served += 1
                var response = Data("HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nConnection: close\r\n\r\n".utf8)
                response.append(body)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    @Test func keepsGoingWhenTheServerDropsTheConnection() async throws {
        let fixture = try #require(Bundle.module.url(forResource: "h264_mp2", withExtension: "ts", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: fixture)
        // Split on a transport stream packet boundary (188 bytes).
        let half = data.count / 188 / 2 * 188
        let server = FlakyServer(chunks: [data.prefix(half), data.suffix(from: half)])
        let port = try await server.start()
        defer { server.stop() }

        let directory = URL.temporaryDirectory.appending(component: "LiveReconnectTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = BridgeSource(url: URL(string: "http://127.0.0.1:\(port)/live")!, isLive: true)
        let bridge = HLSBridge(source: source, directory: directory)
        bridge.start { _ in }
        defer { bridge.cancel() }

        // The first half alone completes one 2-second segment (the one still being written isn't listed yet).
        // With the reconnect, the second half completes another.
        var seconds = 0.0
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(100))
            let playlist = (try? String(contentsOf: directory.appending(component: HLSBridge.playlistName), encoding: .utf8)) ?? ""
            seconds = playlist.split(separator: "\n").filter { $0.hasPrefix("#EXTINF:") }
                .compactMap { Double($0.dropFirst(8).split(separator: ",")[0]) }.reduce(0, +)
            if seconds > 3 { break }
            #expect(!playlist.contains("#EXT-X-ENDLIST"), "A live playlist must not be marked finished")
        }
        #expect(seconds > 3)
    }
}
