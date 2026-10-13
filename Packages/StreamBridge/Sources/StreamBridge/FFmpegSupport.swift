// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import FFmpeg
import Foundation

/// An FFmpeg call that failed.
public struct FFmpegError: Error, LocalizedError, Sendable {
    public let code: Int32
    public let operation: String

    init(_ code: Int32, _ operation: String) {
        self.code = code
        self.operation = operation
    }

    public var errorDescription: String? {
        var buffer = [CChar](repeating: 0, count: 256)
        av_strerror(code, &buffer, buffer.count)
        let message = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return "\(operation): \(message)"
    }
}

/// FFmpeg's error and timestamp macros, which Swift can't import.
enum AV {
    static let eof: Int32 = -fourCC("E", "O", "F", " ")
    static let again: Int32 = -EAGAIN
    static let noPTS = Int64.min
    static let exit: Int32 = -fourCC("E", "X", "I", "T")
    static let invalidData: Int32 = -fourCC("I", "N", "D", "A")

    private static func fourCC(_ a: Character, _ b: Character, _ c: Character, _ d: Character) -> Int32 {
        Int32(a.asciiValue!) | Int32(b.asciiValue!) << 8 | Int32(c.asciiValue!) << 16 | Int32(d.asciiValue!) << 24
    }
}

/// Throws when an FFmpeg call returns an error code.
@discardableResult
func check(_ code: Int32, _ operation: @autoclosure () -> String) throws -> Int32 {
    if code < 0 { throw FFmpegError(code, operation()) }
    return code
}

/// Builds an `AVDictionary` of options. The caller frees it with `av_dict_free`.
func makeDictionary(_ values: [String: String]) -> OpaquePointer? {
    var dictionary: OpaquePointer?
    for (key, value) in values { av_dict_set(&dictionary, key, value, 0) }
    return dictionary
}

func codecName(_ id: AVCodecID) -> String {
    String(cString: avcodec_get_name(id))
}

extension AVRational {
    var seconds: Double { den == 0 ? 0 : Double(num) / Double(den) }
}
