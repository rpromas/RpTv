// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import FFmpeg
import Foundation
@testable import StreamBridge
import Testing

/// Builds DVB teletext the way a broadcaster's encoder does (EN 300 706 packets in EN 300 472 PES data).
enum TeletextEncoder {
    /// A page header. `option` is C12–C14 with C12 the most significant bit.
    static func header(magazine: Int, page: Int, subtitle: Bool = true, erase: Bool = true, serial: Bool = false,
                       option: Int = 0) -> [UInt8] {
        let control = (serial ? 1 : 0) | (option >> 2 & 1) << 1 | (option >> 1 & 1) << 2 | (option & 1) << 3
        let fields = [page & 0xF, page >> 4, 0, erase ? 8 : 0, 0, subtitle ? 8 : 0, 0, control]
        return packet(magazine: magazine, row: 0, payload: fields.map(Teletext.encodeHamming84) + text(String(repeating: " ", count: 32)))
    }

    /// A display row of 40 characters, `codes` padded with spaces.
    static func row(magazine: Int, _ row: Int, _ codes: [UInt8]) -> [UInt8] {
        let padded = (codes + Array(repeating: 0x20, count: 40)).prefix(40)
        return packet(magazine: magazine, row: row, payload: padded.map(odd))
    }

    /// Text inside a box, as subtitles are sent.
    static func boxed(_ text: String) -> [UInt8] {
        boxed(Array(text.utf8))
    }

    static func boxed(_ codes: [UInt8]) -> [UInt8] {
        [0x0B, 0x0B] + codes + [0x0A, 0x0A]
    }

    /// Packet X/28/0 format 1 (or M/29/0 with `row` 29) designating the default G0 set.
    static func designation(magazine: Int, row: Int = 28, group: Int, option: Int) -> [UInt8] {
        let triplet = Teletext.encodeHamming2418((group << 3 | option) << 7)
        let rest = (0..<12).flatMap { _ in Teletext.encodeHamming2418(0) }
        return packet(magazine: magazine, row: row, payload: [Teletext.encodeHamming84(0)] + triplet + rest)
    }

    /// PES data: the data identifier and each packet as a subtitle data unit, padded with stuffing units so
    /// the PES packet fills whole transport packets.
    static func pes(_ packets: [[UInt8]]) -> [UInt8] {
        var data: [UInt8] = [0x10]
        for packet in packets { data += [0x03, 44] + packet }
        while (data.count + 45) % 184 != 0 { data += [0xFF, 44] + Array(repeating: 0xFF, count: 44) }
        return data
    }

    private static func packet(magazine: Int, row: Int, payload: [UInt8]) -> [UInt8] {
        let address = (magazine & 7) | row << 3
        let bits = [Teletext.encodeHamming84(address & 0xF), Teletext.encodeHamming84(address >> 4)] + payload
        // Field and line byte, framing code, then the packet least significant bit first.
        return [0x02, 0xE4] + bits.map(Teletext.reversed)
    }

    private static func text(_ string: String) -> [UInt8] {
        string.utf8.map(odd)
    }

    static func odd(_ code: UInt8) -> UInt8 {
        code.nonzeroBitCount % 2 == 0 ? code | 0x80 : code
    }
}

struct TeletextCodingTests {
    @Test func hamming84CorrectsSingleErrors() {
        for data in 0..<16 {
            let code = Teletext.encodeHamming84(data)
            #expect(Teletext.hamming84(code) == data)
            for bit in 0..<8 { #expect(Teletext.hamming84(code ^ (1 << bit)) == data) }
            #expect(Teletext.hamming84(code ^ 0b11) == nil)
        }
    }

    @Test func hamming2418CorrectsSingleErrors() {
        for data in [0, 1, 0x2AAAA, 0x15555, 0x3FFFF, 0x1234 << 2] {
            let bytes = Teletext.encodeHamming2418(data)
            #expect(Teletext.hamming2418(bytes[0], bytes[1], bytes[2]) == data)
            for bit in 0..<24 {
                var damaged = bytes
                damaged[bit / 8] ^= 1 << (bit % 8)
                #expect(Teletext.hamming2418(damaged[0], damaged[1], damaged[2]) == data)
            }
            #expect(Teletext.hamming2418(bytes[0] ^ 0b101, bytes[1], bytes[2]) == nil)
        }
    }

    @Test func charactersSetsCoverEveryCode() {
        for charset in [TeletextCharset(.cyrillic1), TeletextCharset(.cyrillic2), TeletextCharset(.cyrillic3),
                        TeletextCharset(.greek)] + TeletextCharset.LatinSubset.allCases.map({ TeletextCharset(.latin($0)) }) {
            for code in UInt8(0x20)...0x7E { #expect(charset.character(code) != nil) }
        }
        #expect(TeletextCharset(group: 0, option: 1).character(0x7E) == "ß")
        #expect(TeletextCharset(group: 4, option: 4).character(0x50) == "П")
        #expect(TeletextCharset(group: 6, option: 7).character(0x61) == "α")
        #expect(TeletextCharset(group: 1, option: 0).character(0x5D) == "Ł")
        // Unassigned entries fall back to English.
        #expect(TeletextCharset(group: 5, option: 0) == TeletextCharset(.latin(.english)))
    }
}

struct TeletextDecoderTests {
    private let page888 = TeletextPage(magazine: 8, number: 0x88)

    private func decoder(_ pages: [TeletextPage: String?] = [:]) -> TeletextDecoder {
        TeletextDecoder(listedPages: pages, idBase: 0)
    }

    private func texts(_ updates: [TeletextDecoder.Update]) -> [String] {
        updates.map { if case .text(let text) = $0.cue.content { text } else { "<image>" } }
    }

    @Test func decodesBoxedSubtitles() {
        let decoder = decoder([page888: "eng"])
        let updates = decoder.decode(TeletextEncoder.pes([
            TeletextEncoder.header(magazine: 8, page: 0x88),
            // Text outside the box isn't meant to show.
            TeletextEncoder.row(magazine: 8, 20, Array("hidden".utf8) + TeletextEncoder.boxed("Hello there,")),
            TeletextEncoder.row(magazine: 8, 22, [0x07] + TeletextEncoder.boxed("general  Kenobi")),
        ]), time: 12)
        #expect(texts(updates) == ["Hello there,\ngeneral Kenobi"])
        #expect(updates.first?.page == page888)
        #expect(updates.first?.cue.start == 12)
    }

    @Test func clearsAndSkipsRepeats() {
        let decoder = decoder([page888: nil])
        let page = [TeletextEncoder.header(magazine: 8, page: 0x88),
                    TeletextEncoder.row(magazine: 8, 22, TeletextEncoder.boxed("Once"))]
        #expect(texts(decoder.decode(TeletextEncoder.pes(page), time: 1)) == ["Once"])
        // The same page again a moment later changes nothing on screen.
        #expect(decoder.decode(TeletextEncoder.pes(page), time: 1.5).isEmpty)
        // An erased page with no rows clears it.
        #expect(texts(decoder.decode(TeletextEncoder.pes([TeletextEncoder.header(magazine: 8, page: 0x88)]), time: 3)) == [""])
    }

    @Test func usesTheNationalOption() {
        let decoder = decoder([page888: "deu"])
        let updates = decoder.decode(TeletextEncoder.pes([
            TeletextEncoder.header(magazine: 8, page: 0x88, option: 1),
            TeletextEncoder.row(magazine: 8, 22, TeletextEncoder.boxed(Array("Gr".utf8) + [0x7C, 0x7E] + Array("e".utf8))),
        ]), time: 0)
        #expect(texts(updates) == ["Größe"])
    }

    @Test func guessesCyrillicFromTheLanguage() {
        let decoder = decoder([page888: "rus"])
        let updates = decoder.decode(TeletextEncoder.pes([
            TeletextEncoder.header(magazine: 8, page: 0x88, option: 4),
            TeletextEncoder.row(magazine: 8, 22, TeletextEncoder.boxed([0x50, 0x72, 0x69, 0x77, 0x65, 0x74])),
        ]), time: 0)
        #expect(texts(updates) == ["Привет"])
    }

    @Test func followsTheDesignationPacket() {
        let decoder = decoder([page888: nil])
        let updates = decoder.decode(TeletextEncoder.pes([
            TeletextEncoder.header(magazine: 8, page: 0x88, option: 7),
            TeletextEncoder.designation(magazine: 8, group: 6, option: 7),
            TeletextEncoder.row(magazine: 8, 22, [0x0B, 0x0B, 0x61, 0x62, 0x63]),
        ]), time: 0)
        #expect(texts(updates) == ["αβγ"])
    }

    @Test func findsUnlistedSubtitlePagesOnly() {
        let decoder = decoder()
        _ = decoder.decode(TeletextEncoder.pes([
            TeletextEncoder.header(magazine: 1, page: 0x00, subtitle: false),
            TeletextEncoder.row(magazine: 1, 5, Array("News index".utf8)),
            TeletextEncoder.header(magazine: 7, page: 0x77),
            TeletextEncoder.row(magazine: 7, 22, TeletextEncoder.boxed("Found")),
        ]), time: 0)
        #expect(decoder.foundPages == [TeletextPage(magazine: 7, number: 0x77)])
        #expect(TeletextPage(magazine: 7, number: 0x77).label == "777")
    }

    @Test func serialModeEndsThePageAtAnyHeader() {
        let decoder = decoder([page888: nil])
        let updates = decoder.decode(TeletextEncoder.pes([
            TeletextEncoder.header(magazine: 8, page: 0x88, serial: true),
            TeletextEncoder.row(magazine: 8, 22, TeletextEncoder.boxed("Mine")),
            // Another magazine's page starts; rows after it aren't for 888.
            TeletextEncoder.header(magazine: 1, page: 0x00, subtitle: false, serial: true),
            TeletextEncoder.row(magazine: 8, 23, TeletextEncoder.boxed("Not mine")),
        ]), time: 0)
        #expect(texts(updates) == ["Mine"])
    }
}

/// A transport stream with German teletext subtitles on page 888, played through the whole player.
@Suite(.serialized)
struct TeletextPlaybackTests {
    static func makeFixture() throws -> URL {
        let url = URL.temporaryDirectory.appending(component: "teletext-\(UUID().uuidString).ts")
        var output: UnsafeMutablePointer<AVFormatContext>?
        try #require(avformat_alloc_output_context2(&output, nil, "mpegts", url.path) >= 0)
        defer {
            avio_closep(&output!.pointee.pb)
            avformat_free_context(output)
        }
        let codec = try #require(avcodec_find_encoder(AV_CODEC_ID_MPEG2VIDEO))
        var encoder: UnsafeMutablePointer<AVCodecContext>? = avcodec_alloc_context3(codec)
        defer { avcodec_free_context(&encoder) }
        encoder!.pointee.width = 160
        encoder!.pointee.height = 120
        encoder!.pointee.pix_fmt = AV_PIX_FMT_YUV420P
        encoder!.pointee.time_base = AVRational(num: 1, den: 25)
        encoder!.pointee.framerate = AVRational(num: 25, den: 1)
        encoder!.pointee.gop_size = 12
        encoder!.pointee.max_b_frames = 0
        try #require(avcodec_open2(encoder, codec, nil) >= 0)
        let video = avformat_new_stream(output, nil)!
        avcodec_parameters_from_context(video.pointee.codecpar, encoder)
        video.pointee.time_base = encoder!.pointee.time_base

        let teletext = avformat_new_stream(output, nil)!
        teletext.pointee.codecpar.pointee.codec_type = AVMEDIA_TYPE_SUBTITLE
        teletext.pointee.codecpar.pointee.codec_id = AV_CODEC_ID_DVB_TELETEXT
        teletext.pointee.time_base = AVRational(num: 1, den: 90000)
        // One subtitle page, 888, for German.
        let descriptor: [UInt8] = [0x02 << 3 | 0, 0x88]
        teletext.pointee.codecpar.pointee.extradata = av_mallocz(descriptor.count + Int(AV_INPUT_BUFFER_PADDING_SIZE))!
            .assumingMemoryBound(to: UInt8.self)
        teletext.pointee.codecpar.pointee.extradata.update(from: descriptor, count: descriptor.count)
        teletext.pointee.codecpar.pointee.extradata_size = Int32(descriptor.count)
        av_dict_set(&teletext.pointee.metadata, "language", "deu", 0)

        try #require(avio_open(&output!.pointee.pb, url.path, AVIO_FLAG_WRITE) >= 0)
        try #require(avformat_write_header(output, nil) >= 0)

        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        var packet: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer {
            av_frame_free(&frame)
            av_packet_free(&packet)
        }
        func drain() throws {
            while avcodec_receive_packet(encoder, packet) >= 0 {
                av_packet_rescale_ts(packet, encoder!.pointee.time_base, video.pointee.time_base)
                packet!.pointee.stream_index = 0
                try #require(av_interleaved_write_frame(output, packet) >= 0)
            }
        }
        func subtitle(at seconds: Double, _ data: [UInt8]) throws {
            try #require(av_new_packet(packet, Int32(data.count)) >= 0)
            packet!.pointee.data.update(from: data, count: data.count)
            packet!.pointee.pts = Int64(seconds * 90000)
            packet!.pointee.dts = packet!.pointee.pts
            packet!.pointee.stream_index = 1
            try #require(av_interleaved_write_frame(output, packet) >= 0)
        }
        for index in 0..<75 {
            frame!.pointee.width = 160
            frame!.pointee.height = 120
            frame!.pointee.format = AV_PIX_FMT_YUV420P.rawValue
            try #require(av_frame_get_buffer(frame, 0) >= 0)
            for plane in 0..<3 {
                let data = [frame!.pointee.data.0, frame!.pointee.data.1, frame!.pointee.data.2][plane]!
                let lines = [frame!.pointee.linesize.0, frame!.pointee.linesize.1, frame!.pointee.linesize.2][plane]
                memset(data, 128, Int(lines) * (plane == 0 ? 120 : 60))
            }
            frame!.pointee.pts = Int64(index)
            try #require(avcodec_send_frame(encoder, frame) >= 0)
            av_frame_unref(frame)
            try drain()
            if index == 25 {
                try subtitle(at: 1, TeletextEncoder.pes([
                    TeletextEncoder.header(magazine: 8, page: 0x88, option: 1),
                    TeletextEncoder.row(magazine: 8, 22, TeletextEncoder.boxed(Array("Gr".utf8) + [0x7B] + Array("n".utf8))),
                ]))
            } else if index == 50 {
                try subtitle(at: 2, TeletextEncoder.pes([TeletextEncoder.header(magazine: 8, page: 0x88, option: 1)]))
            }
        }
        avcodec_send_frame(encoder, nil)
        try drain()
        try #require(av_write_trailer(output) >= 0)
        return url
    }

    @Test func listsAndShowsTeletextSubtitles() async throws {
        let url = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let player = StreamPlayer()
        defer { player.stop() }
        let recorder = StreamPlayerTests.Recorder()
        player.start(PlayerSource(url: url, isLive: false, buffer: 0.5,
                                  prefersSubtitleLanguage: { @Sendable language in language == "deu" })) {
            recorder.record($0)
        }

        let deadline = ContinuousClock.now + .seconds(10)
        func wait(_ condition: () -> Bool) async throws {
            while !condition() {
                try #require(ContinuousClock.now < deadline, "Timed out")
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        try await wait { !recorder.tracks.isEmpty }
        let track = try #require(recorder.tracks.first { $0.kind == .subtitle })
        #expect(track.codec == "dvb_teletext")
        #expect(track.language == "deu")
        #expect(track.isSelected)

        try await wait { recorder.subtitles.contains("Grän") }
        try await wait { recorder.statuses.last == .ended }
        #expect(recorder.lastCue == nil)
    }
}
