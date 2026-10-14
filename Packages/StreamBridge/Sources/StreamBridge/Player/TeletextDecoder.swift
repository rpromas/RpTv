// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// A teletext page address: magazine 1–8 and page 0x00–0xFF, written "888".
struct TeletextPage: Hashable, Sendable {
    var magazine: Int
    var number: Int

    var label: String { "\(magazine)\(String(number, radix: 16, uppercase: true).leftPadded(to: 2))" }
}

/// Decodes the subtitle pages of a DVB teletext stream (ETSI EN 300 472 carrying EN 300 706) into cues.
///
/// Only what subtitles need: page headers, display rows 1–23, the character set designations in packets X/28 and
/// M/29, boxed text, and the Latin, Cyrillic and Greek character sets. Colours, mosaics and the accented letters
/// that level 1.5 adds through packets X/26 are left out.
///
/// A page is shown when the PES packet carrying it ends: subtitle encoders send each subtitle as one page in one
/// packet, timed to appear at that packet's timestamp. A page sent again with the erase bit and no rows clears
/// the screen.
final class TeletextDecoder {
    struct Update {
        var page: TeletextPage
        var cue: SubtitleCue
    }

    /// How long a subtitle stays up if the broadcaster never clears it.
    static let maxDuration = 15.0

    private struct PageState {
        var rows: [[UInt8]?] = Array(repeating: nil, count: 24)
        var option = 0
        /// Bits 8–14 of an X/28/0 or X/28/4 packet for the page.
        var designation: Int?
        var isDirty = false
        var shownText: String?
        var shownAt = -Double.infinity
    }

    /// Pages to decode even without the subtitle bit, with their language: what the stream's descriptor lists.
    private let listed: [TeletextPage: String?]
    private let fallbackLanguage: String?
    private var pages: [TeletextPage: PageState] = [:]
    /// The page each magazine is sending rows for, if it's one being decoded.
    private var receiving: [Int: TeletextPage] = [:]
    private var magazineDesignations: [Int: Int] = [:]
    private var nextID: Int
    /// Subtitle pages found in the stream, beyond the listed ones.
    private(set) var foundPages: [TeletextPage] = []

    init(listedPages: [TeletextPage: String?], idBase: Int) {
        listed = listedPages
        fallbackLanguage = listedPages.values.compactMap { $0 }.first
        nextID = idBase
    }

    /// Forgets everything received, after a seek.
    func reset() {
        for page in pages.keys {
            pages[page] = PageState()
        }
        receiving = [:]
    }

    /// Decodes one PES payload, as FFmpeg's demuxer hands it over, and returns what changed on screen at `time`.
    func decode(_ data: [UInt8], time: Double) -> [Update] {
        // EBU data (EN 300 472), or EBU teletext and VPS (EN 301 775).
        guard let identifier = data.first, (0x10...0x1F).contains(identifier) || (0x99...0x9B).contains(identifier) else {
            return []
        }
        var index = 1
        while index + 2 <= data.count {
            let unit = data[index], length = Int(data[index + 1])
            index += 2
            guard index + length <= data.count else { break }
            // Teletext, non-subtitle (0x02) or subtitle (0x03). Stuffing (0xFF) and anything else is skipped.
            if unit == 0x02 || unit == 0x03, length == 44 {
                receive(data[index..<index + 44])
            }
            index += length
        }
        return show(at: time)
    }

    // MARK: - Packets

    private func receive(_ unit: ArraySlice<UInt8>) {
        let bytes = Array(unit)
        // Byte 0 is the field and line; then the framing code, which DVB sends as 0xE4.
        guard bytes[1] == 0xE4 else { return }
        // Everything after the framing code is sent least significant bit first, as on the VBI line.
        let packet = bytes[2...].map(Teletext.reversed)
        guard let low = Teletext.hamming84(packet[0]), let high = Teletext.hamming84(packet[1]) else { return }
        let address = low | high << 4
        let magazine = address & 7 == 0 ? 8 : address & 7
        let row = address >> 3
        let payload = Array(packet[2...])

        switch row {
        case 0:
            header(payload, magazine: magazine)
        case 1...23:
            guard let page = receiving[magazine] else { return }
            pages[page]?.rows[row] = payload
            pages[page]?.isDirty = true
        case 28:
            guard let page = receiving[magazine], let code = designation(payload) else { return }
            pages[page]?.designation = code
        case 29:
            if let code = designation(payload) { magazineDesignations[magazine] = code }
        default:
            break
        }
    }

    private func header(_ payload: [UInt8], magazine: Int) {
        guard let units = Teletext.hamming84(payload[0]), let tens = Teletext.hamming84(payload[1]),
              let s2 = Teletext.hamming84(payload[3]), let s4 = Teletext.hamming84(payload[5]),
              let control = Teletext.hamming84(payload[7]) else { return }
        let page = TeletextPage(magazine: magazine, number: tens << 4 | units)
        let erase = s2 & 8 != 0
        let isSubtitle = s4 & 8 != 0
        let serial = control & 1 != 0
        // C12 is the most significant bit of the option (clause 15.2).
        let option = (control >> 1 & 1) << 2 | (control >> 2 & 1) << 1 | control >> 3 & 1

        // A header ends the page being sent in its magazine, or in every magazine in serial mode.
        if serial {
            receiving = receiving.filter { $0.value == page }
        }
        receiving[magazine] = nil
        // Page FF only fills time.
        guard units <= 9, tens <= 9 else { return }
        guard isSubtitle || listed[page] != nil else { return }
        if pages[page] == nil {
            pages[page] = PageState()
            if listed[page] == nil { foundPages.append(page) }
        }
        receiving[magazine] = page
        pages[page]!.option = option
        if erase {
            pages[page]!.rows = Array(repeating: nil, count: 24)
            pages[page]!.designation = nil
            pages[page]!.isDirty = true
        }
    }

    /// The default G0 set designation (triplet 1, bits 8–14) of a packet X/28 or M/29 in format 1 or 4.
    private func designation(_ payload: [UInt8]) -> Int? {
        guard let code = Teletext.hamming84(payload[0]), code == 0 || code == 4,
              let triplet = Teletext.hamming2418(payload[1], payload[2], payload[3]) else { return nil }
        return triplet >> 7 & 0x7F
    }

    // MARK: - Display

    private func show(at time: Double) -> [Update] {
        var updates: [Update] = []
        for (page, var state) in pages where state.isDirty {
            state.isDirty = false
            let text = self.text(of: state, page: page)
            // Pages are repeated; only a change, or keeping a long subtitle up, is worth a new cue.
            if text == state.shownText, time - state.shownAt < Self.maxDuration / 3 {
                pages[page] = state
                continue
            }
            if text.isEmpty, state.shownText?.isEmpty ?? true {
                pages[page] = state
                continue
            }
            state.shownText = text
            state.shownAt = time
            pages[page] = state
            nextID += 1
            updates.append(Update(page: page, cue: SubtitleCue(id: nextID, start: time, end: time + Self.maxDuration,
                                                              content: .text(text))))
        }
        return updates
    }

    private func charset(for state: PageState, page: TeletextPage) -> TeletextCharset {
        let language = listed[page] ?? fallbackLanguage
        let group = (state.designation ?? magazineDesignations[page.magazine]).map { $0 >> 3 }
            ?? TeletextCharset.group(forLanguage: language) ?? 0
        return TeletextCharset(group: group, option: state.option)
    }

    /// The page's text, one line per non-empty row. On pages that use boxes (all subtitle pages should), only
    /// boxed text counts: the rest is meant to stay hidden.
    private func text(of state: PageState, page: TeletextPage) -> String {
        let charset = charset(for: state, page: page)
        let rows = state.rows[1...23].compactMap { $0 }
        let boxed = rows.contains { $0.contains { Teletext.parity($0) == 0x0B } }
        var lines: [String] = []
        for row in rows {
            var line = ""
            var inBox = false
            var mosaic = false
            for byte in row {
                guard let code = Teletext.parity(byte) else {
                    line.append(" ")
                    continue
                }
                switch code {
                case 0x00...0x07:
                    mosaic = false
                    line.append(" ")
                case 0x10...0x17:
                    mosaic = true
                    line.append(" ")
                case 0x0B:
                    inBox = true
                    line.append(" ")
                case 0x0A:
                    inBox = false
                    line.append(" ")
                case 0x00...0x1F:
                    line.append(" ")
                default:
                    // Mosaic mode draws blocks for everything but capital letters.
                    let isBlock = mosaic && !(0x40...0x5F).contains(code)
                    if isBlock || (boxed && !inBox) {
                        line.append(" ")
                    } else {
                        line.append(charset.character(code) ?? " ")
                    }
                }
            }
            let trimmed = line.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            if !trimmed.isEmpty { lines.append(trimmed) }
        }
        return lines.joined(separator: "\n")
    }
}

/// The error protection teletext uses (EN 300 706 clause 8).
enum Teletext {
    /// Each byte with its bits in the opposite order.
    static func reversed(_ byte: UInt8) -> UInt8 {
        reverseTable[Int(byte)]
    }

    /// The 7 data bits of an odd-parity byte, or `nil` when the parity is wrong.
    static func parity(_ byte: UInt8) -> UInt8? {
        byte.nonzeroBitCount % 2 == 1 ? byte & 0x7F : nil
    }

    /// The 4 data bits of a Hamming 8/4 byte (bits received least significant first), single errors corrected,
    /// or `nil` for a double error.
    static func hamming84(_ byte: UInt8) -> Int? {
        let value = hamming84Table[Int(byte)]
        return value < 0 ? nil : Int(value)
    }

    /// Encodes 4 data bits as Hamming 8/4.
    static func encodeHamming84(_ data: Int) -> UInt8 {
        let d = (0..<4).map { data >> $0 & 1 }
        let p1 = 1 ^ d[0] ^ d[2] ^ d[3]
        let p2 = 1 ^ d[0] ^ d[1] ^ d[3]
        let p3 = 1 ^ d[0] ^ d[1] ^ d[2]
        let p4 = 1 ^ p1 ^ d[0] ^ p2 ^ d[1] ^ p3 ^ d[2] ^ d[3]
        let bits = [p1, d[0], p2, d[1], p3, d[2], p4, d[3]]
        return UInt8(bits.enumerated().reduce(0) { $0 | $1.element << $1.offset })
    }

    /// The 18 data bits of a Hamming 24/18 triplet (bytes in order received), a single error corrected, or `nil`.
    static func hamming2418(_ first: UInt8, _ second: UInt8, _ third: UInt8) -> Int? {
        let received = Int(first) | Int(second) << 8 | Int(third) << 16
        let data = extract2418(received)
        if encodeHamming2418Bits(data) == received { return data }
        // One bit wrong: find the flip that makes the triplet consistent.
        for bit in 0..<24 {
            let candidate = received ^ (1 << bit)
            let corrected = extract2418(candidate)
            if encodeHamming2418Bits(corrected) == candidate { return corrected }
        }
        return nil
    }

    /// Encodes 18 data bits as a Hamming 24/18 triplet, as three bytes in transmission order.
    static func encodeHamming2418(_ data: Int) -> [UInt8] {
        let bits = encodeHamming2418Bits(data)
        return [UInt8(bits & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits >> 16 & 0xFF)]
    }

    /// Positions (1-based, transmission order) of D1…D18; the others hold protection bits.
    private static let dataPositions = [3, 5, 6, 7, 9, 10, 11, 12, 13, 14, 15, 17, 18, 19, 20, 21, 22, 23]

    private static func extract2418(_ bits: Int) -> Int {
        dataPositions.enumerated().reduce(0) { $0 | (bits >> ($1.element - 1) & 1) << $1.offset }
    }

    private static func encodeHamming2418Bits(_ data: Int) -> Int {
        let d = [0] + (0..<18).map { data >> $0 & 1 } // 1-based: d[1] is D1
        let p1 = 1 ^ d[1] ^ d[2] ^ d[4] ^ d[5] ^ d[7] ^ d[9] ^ d[11] ^ d[12] ^ d[14] ^ d[16] ^ d[18]
        let p2 = 1 ^ d[1] ^ d[3] ^ d[4] ^ d[6] ^ d[7] ^ d[10] ^ d[11] ^ d[13] ^ d[14] ^ d[17] ^ d[18]
        let p3 = 1 ^ d[2] ^ d[3] ^ d[4] ^ d[8] ^ d[9] ^ d[10] ^ d[11] ^ d[15] ^ d[16] ^ d[17] ^ d[18]
        let p4 = 1 ^ d[5] ^ d[6] ^ d[7] ^ d[8] ^ d[9] ^ d[10] ^ d[11]
        let p5 = 1 ^ d[12] ^ d[13] ^ d[14] ^ d[15] ^ d[16] ^ d[17] ^ d[18]
        var bits = p1 | p2 << 1 | p4 << 7 | p5 << 15
        bits |= p3 << 3
        for (index, position) in dataPositions.enumerated() {
            bits |= d[index + 1] << (position - 1)
        }
        // P6 makes the parity of all 24 bits odd.
        let p6 = 1 ^ (bits.nonzeroBitCount & 1)
        return bits | p6 << 23
    }

    private static let reverseTable: [UInt8] = (0...255).map { value in
        (0..<8).reduce(UInt8(0)) { $0 | UInt8(value >> $1 & 1) << (7 - $1) }
    }

    /// Every byte within one bit of a codeword decodes to that codeword's data; anything else is -1.
    private static let hamming84Table: [Int8] = {
        var table = [Int8](repeating: -1, count: 256)
        for data in 0..<16 {
            let code = encodeHamming84(data)
            table[Int(code)] = Int8(data)
            for bit in 0..<8 { table[Int(code ^ (1 << bit))] = Int8(data) }
        }
        return table
    }()
}

private extension String {
    func leftPadded(to length: Int) -> String {
        String(repeating: "0", count: max(0, length - count)) + self
    }
}
