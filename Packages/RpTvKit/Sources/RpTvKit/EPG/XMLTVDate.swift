// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Parses XMLTV timestamps such as `20261013120000 +0200`.
///
/// Seconds, minutes and the offset may be missing; without an offset the time is taken as UTC.
/// Hand-rolled because guides hold hundreds of thousands of timestamps and `DateFormatter` is slow.
enum XMLTVDate {
    static func parse(_ text: String) -> Date? {
        var text = text
        return text.withUTF8 { parse(bytes: $0) }
    }

    private static func parse(bytes: UnsafeBufferPointer<UInt8>) -> Date? {
        var index = 0
        func number(_ length: Int) -> Int? {
            guard index + length <= bytes.count else { return nil }
            var value = 0
            for _ in 0..<length {
                let digit = Int(bytes[index]) - 48
                guard (0...9).contains(digit) else { return nil }
                value = value * 10 + digit
                index += 1
            }
            return value
        }
        func hasDigit() -> Bool { index < bytes.count && (48...57).contains(bytes[index]) }

        guard let year = number(4), let month = number(2), let day = number(2), let hour = number(2),
              (1...12).contains(month), (1...31).contains(day), hour < 24 else { return nil }
        let minute = hasDigit() ? number(2) : 0
        let second = hasDigit() ? number(2) : 0
        guard let minute, let second, minute < 60, second < 61 else { return nil }

        while index < bytes.count, bytes[index] == UInt8(ascii: " ") { index += 1 }
        var offset = 0
        if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
            let sign = bytes[index] == UInt8(ascii: "-") ? -1 : 1
            index += 1
            guard let hours = number(2) else { return nil }
            if index < bytes.count, bytes[index] == UInt8(ascii: ":") { index += 1 }
            let minutes = hasDigit() ? number(2) ?? 0 : 0
            offset = sign * (hours * 3600 + minutes * 60)
        }

        let seconds = daysFromCivil(year: year, month: month, day: day) * 86400 + hour * 3600 + minute * 60 + second - offset
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar (Howard Hinnant's algorithm).
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146097 + dayOfEra - 719468
    }
}
