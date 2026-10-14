// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import FFmpeg
import Foundation
@testable import StreamBridge
import Testing

/// Closed captions (CEA-608) inside MPEG-2 video, as US broadcasts carry them.
@Suite(.serialized)
struct CaptionTests {
    /// Writes three seconds of MPEG-2 video at 25 fps whose captions pop on "HI THERE" at frame 20 (0.8 s) and
    /// clear it at frame 50 (2 s).
    static func makeFixture() throws -> URL {
        let url = URL.temporaryDirectory.appending(component: "captions-\(UUID().uuidString).ts")
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
        let stream = avformat_new_stream(output, nil)!
        avcodec_parameters_from_context(stream.pointee.codecpar, encoder)
        stream.pointee.time_base = encoder!.pointee.time_base
        try #require(avio_open(&output!.pointee.pb, url.path, AVIO_FLAG_WRITE) >= 0)
        try #require(avformat_write_header(output, nil) >= 0)

        var pairs = [Int: (UInt8, UInt8)]()
        func control(_ first: Int, _ code: (UInt8, UInt8)) { pairs[first] = code; pairs[first + 1] = code }
        control(10, (0x14, 0x20))  // Resume caption loading (pop-on)
        control(12, (0x14, 0x2E))  // Erase non-displayed memory
        control(14, (0x14, 0x60))  // Row 15
        for (offset, text) in ["HI", " T", "HE", "RE"].enumerated() {
            let bytes = Array(text.utf8)
            pairs[16 + offset] = (bytes[0], bytes[1])
        }
        control(20, (0x14, 0x2F))  // End of caption: show it
        control(50, (0x14, 0x2C))  // Erase displayed memory

        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        var packet: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer {
            av_frame_free(&frame)
            av_packet_free(&packet)
        }
        func drain() throws {
            while avcodec_receive_packet(encoder, packet) >= 0 {
                av_packet_rescale_ts(packet, encoder!.pointee.time_base, stream.pointee.time_base)
                packet!.pointee.stream_index = 0
                try #require(av_interleaved_write_frame(output, packet) >= 0)
            }
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
            let pair = pairs[index] ?? (0, 0)
            let side = av_frame_new_side_data(frame, AV_FRAME_DATA_A53_CC, 3)!
            // Field 1, valid, NTSC line 21; CEA-608 bytes carry odd parity.
            side.pointee.data[0] = 0xFC
            side.pointee.data[1] = oddParity(pair.0)
            side.pointee.data[2] = oddParity(pair.1)
            try #require(avcodec_send_frame(encoder, frame) >= 0)
            av_frame_unref(frame)
            try drain()
        }
        avcodec_send_frame(encoder, nil)
        try drain()
        try #require(av_write_trailer(output) >= 0)
        return url
    }

    private static func oddParity(_ byte: UInt8) -> UInt8 {
        byte.nonzeroBitCount % 2 == 0 ? byte | 0x80 : byte
    }

    @Test func findsAndShowsCaptions() async throws {
        let url = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let player = StreamPlayer()
        defer { player.stop() }
        let recorder = StreamPlayerTests.Recorder()
        player.start(PlayerSource(url: url, isLive: false, buffer: 0.5)) { recorder.record($0) }

        let deadline = ContinuousClock.now + .seconds(10)
        func wait(_ condition: () -> Bool) async throws {
            while !condition() {
                try #require(ContinuousClock.now < deadline, "Timed out")
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        // The captions appear as a track once the first one is decoded.
        try await wait { recorder.tracks.contains { $0.codec == "eia_608" } }
        let captions = try #require(recorder.tracks.first { $0.codec == "eia_608" })
        #expect(captions.kind == .subtitle)
        #expect(!captions.isSelected)
        player.selectSubtitle(captions)

        try await wait { recorder.subtitles.contains("HI THERE") }
        // Cleared again at two seconds.
        try await wait { recorder.statuses.last == .ended }
        #expect(recorder.lastCue == nil)
    }
}

extension StreamPlayerTests.Recorder {
    /// The subtitle showing after the latest change, if any.
    var lastCue: SubtitleCue? {
        events.withLock { events in
            for event in events.reversed() {
                if case .subtitle(let cue) = event { return cue }
            }
            return nil
        }
    }
}
