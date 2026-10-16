// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import zlib

public enum GzipError: LocalizedError, Equatable {
    case corrupt

    public var errorDescription: String? { "The compressed TV guide is damaged." }
}

/// Inflates gzip files chunk by chunk, so large guides never have to fit in memory.
enum GzipInflater {
    /// Whether the file starts with the gzip magic bytes. The URL can't be trusted: guides are served under
    /// other names, and URLSession may already have inflated them.
    static func isGzip(_ file: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        return try handle.read(upToCount: 2) == Data([0x1F, 0x8B])
    }

    /// Returns `file` itself when it isn't gzipped, or a new file next to it holding the inflated data.
    static func inflateIfNeeded(_ file: URL) throws -> URL {
        guard try isGzip(file) else { return file }
        let output = file.deletingPathExtension().appendingPathExtension("inflated.xml")
        do {
            try inflate(file, to: output)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return output
    }

    static func inflate(_ source: URL, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        var stream = z_stream()
        // 16 + MAX_WBITS: expect a gzip header and trailer.
        guard inflateInit2_(&stream, 16 + MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw GzipError.corrupt
        }
        defer { inflateEnd(&stream) }

        let chunkSize = 1 << 18
        var outBuffer = [UInt8](repeating: 0, count: chunkSize)
        var finished = false
        while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
            try Task.checkCancellation()
            var inBytes = [UInt8](chunk)
            let inCount = inBytes.count
            var consumed = 0
            while consumed < inCount {
                if finished {
                    // Concatenated gzip members are read one after another; anything else
                    // after the end (padding) is ignored.
                    guard inCount - consumed >= 2, inBytes[consumed] == 0x1F, inBytes[consumed + 1] == 0x8B else { return }
                    guard inflateReset(&stream) == Z_OK else { throw GzipError.corrupt }
                    finished = false
                }
                let status = inBytes.withUnsafeMutableBufferPointer { inPointer in
                    outBuffer.withUnsafeMutableBufferPointer { outPointer in
                        stream.next_in = inPointer.baseAddress! + consumed
                        stream.avail_in = uInt(inCount - consumed)
                        stream.next_out = outPointer.baseAddress
                        stream.avail_out = uInt(chunkSize)
                        let status = zlib.inflate(&stream, Z_NO_FLUSH)
                        consumed = inCount - Int(stream.avail_in)
                        return status
                    }
                }
                switch status {
                case Z_OK, Z_BUF_ERROR: break
                case Z_STREAM_END: finished = true
                default: throw GzipError.corrupt
                }
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 { try output.write(contentsOf: outBuffer[..<produced]) }
                if status == Z_BUF_ERROR && produced == 0 { break }
            }
        }
        guard finished else { throw GzipError.corrupt }
    }
}
