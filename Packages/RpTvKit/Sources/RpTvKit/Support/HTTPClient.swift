// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Minimal HTTP seam so network code can be tested with canned responses.
public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public enum HTTPError: LocalizedError, Equatable {
    case notHTTP
    case status(Int)

    public var errorDescription: String? {
        switch self {
        case .notHTTP: "The server sent an invalid response."
        case .status(let code): "The server responded with HTTP \(code)."
        }
    }
}

extension URLSession: HTTPClient {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HTTPError.notHTTP }
        return (data, http)
    }
}

extension URLRequest {
    init(url: URL, headers: [String: String]) {
        self.init(url: url)
        for (field, value) in headers { setValue(value, forHTTPHeaderField: field) }
    }
}
