// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Network
import OSLog

private let log = Logger(subsystem: "dev.romas.RpTv", category: "StreamBridge")

/// Serves one bridge's HLS files over HTTP, on every interface: AVPlayer reads them locally, and when AirPlay
/// takes over, the Apple TV fetches the same URLs over Wi-Fi. Paths carry a random token, so other devices on
/// the network can't guess them.
public final class HLSServer: @unchecked Sendable {
    public let directory: URL
    public let token = UUID().uuidString.lowercased()
    private let queue = DispatchQueue(label: "dev.romas.RpTv.StreamBridge.HLSServer")
    // Touched only on `queue`.
    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<UInt16, Error>?
    private var connections = 0

    private static let maxConnections = 16
    private static let maxRequestSize = 16 * 1024

    public init(directory: URL) {
        self.directory = directory
    }

    /// Starts listening on a free port and returns it.
    public func start() async throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                self.listener = listener
                startContinuation = continuation
                listener.stateUpdateHandler = { [weak self] state in self?.listenerChanged(to: state) }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.start(queue: queue)
            }
        }
    }

    public func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
        }
    }

    /// The playlist's address on `host`, once the server has started on `port`.
    public func playlistURL(host: String, port: UInt16) -> URL {
        URL(string: "http://\(host):\(port)/\(token)/\(HLSBridge.playlistName)")!
    }

    // MARK: - Connections (on `queue`)

    private func listenerChanged(to state: NWListener.State) {
        guard let continuation = startContinuation else { return }
        switch state {
        case .ready:
            startContinuation = nil
            continuation.resume(returning: listener?.port?.rawValue ?? 0)
        case .failed(let error):
            startContinuation = nil
            continuation.resume(throwing: error)
        case .cancelled:
            startContinuation = nil
            continuation.resume(throwing: CancellationError())
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard connections < Self.maxConnections else {
            connection.cancel()
            return
        }
        connections += 1
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.connections -= 1
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                self.respond(to: head, on: connection)
            } else if error != nil || isComplete || buffer.count > Self.maxRequestSize {
                connection.cancel()
            } else {
                self.receiveRequest(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(to head: String, on connection: NWConnection) {
        let requestLine = head.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else {
            return send(status: "405 Method Not Allowed", body: Data(), type: "text/plain", on: connection)
        }
        let path = parts[1].split(separator: "?").first.map(String.init) ?? ""
        // Shows who fetches what: the phone itself, or an Apple TV once AirPlay takes over.
        let client = connection.currentPath?.remoteEndpoint.map { "\($0)" } ?? "?"
        guard let fileName = Self.fileName(in: path, token: token),
              let body = try? Data(contentsOf: directory.appending(component: fileName)) else {
            log.info("\(parts[0], privacy: .public) \(Self.fileName(in: path, token: self.token) ?? "-", privacy: .public) → 404 for \(client, privacy: .public)")
            return send(status: "404 Not Found", body: Data(), type: "text/plain", on: connection)
        }
        log.info("\(parts[0], privacy: .public) \(fileName, privacy: .public) → 200, \(body.count) bytes, for \(client, privacy: .public)")
        send(status: "200 OK", body: parts[0] == "HEAD" ? Data() : body, type: Self.contentType(for: fileName),
             length: body.count, on: connection)
    }

    private func send(status: String, body: Data, type: String, length: Int? = nil, on connection: NWConnection) {
        let header = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: \(type)\r\n"
            + "Content-Length: \(length ?? body.count)\r\n"
            + "Cache-Control: no-cache\r\n"
            + "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// The file a request path names, if it carries the token and stays inside the directory.
    static func fileName(in path: String, token: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count == 2, components[0] == token else { return nil }
        let name = String(components[1])
        guard !name.hasPrefix("."), name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" })
        else { return nil }
        return name
    }

    static func contentType(for fileName: String) -> String {
        switch (fileName as NSString).pathExtension {
        case "m3u8": "application/vnd.apple.mpegurl"
        case "ts": "video/mp2t"
        case "m4s", "mp4": "video/mp4"
        default: "application/octet-stream"
        }
    }
}
