// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Lenient decoding for inconsistent Xtream JSON: numbers as strings and vice versa, `null` or `""` for missing
/// values, `[]` or `{}` for empty collections. These helpers never throw.
extension KeyedDecodingContainer {
    func lossyString(_ key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value.nonEmpty }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return String(value) }
        return nil
    }

    func lossyInt(_ key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int(value) }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            return Int(trimmed) ?? Double(trimmed).map { Int($0) }
        }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value ? 1 : 0 }
        return nil
    }

    func lossyDouble(_ key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Double(value.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    func lossyBool(_ key: Key) -> Bool {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
        return (lossyInt(key) ?? 0) != 0
    }

    /// Seconds since 1970, sent as a number or a string.
    func lossyUnixDate(_ key: Key) -> Date? {
        guard let seconds = lossyDouble(key) ?? lossyInt(key).map(Double.init), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// A string array, also accepting a single string or a missing value.
    func lossyStrings(_ key: Key) -> [String] {
        if let values = try? decodeIfPresent([String?].self, forKey: key) { return values.compactMap(\.nonEmpty) }
        if let value = lossyString(key) { return [value] }
        return []
    }

    /// Decodes an object, treating `[]`, `null` or a malformed value as missing.
    func lossyObject<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        try? decodeIfPresent(T.self, forKey: key)
    }

    /// Decodes an array, skipping elements that fail. Also accepts an object whose values are the elements.
    func lossyArray<T: Decodable>(_ type: T.Type, _ key: Key) -> [T] {
        if let values = try? decodeIfPresent([Lossy<T>].self, forKey: key) { return values.compactMap(\.value) }
        if let values = try? decodeIfPresent([String: Lossy<T>].self, forKey: key) {
            return values.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.compactMap(\.value.value)
        }
        return []
    }
}

/// Wraps a value whose decoding may fail without failing the enclosing collection.
struct Lossy<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// Accepts any JSON key, for objects with dynamic keys such as Xtream's season-numbered episode lists.
struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) { self.stringValue = stringValue }
    init(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
