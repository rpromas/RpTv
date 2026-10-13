// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import FFmpeg
import Foundation

/// Decodes video Apple can't play (MPEG-2, VC-1, MPEG-4 Part 2, …) and re-encodes it as H.264 with
/// VideoToolbox, deinterlacing on the way when asked to.
final class VideoTranscoder {
    private(set) var encoder: UnsafeMutablePointer<AVCodecContext>?
    private let decoder: UnsafeMutablePointer<AVCodecContext>
    private let deinterlace: Bool
    private let globalHeader: Bool
    private var graph: UnsafeMutablePointer<AVFilterGraph>?
    private var source: UnsafeMutablePointer<AVFilterContext>?
    private var sink: UnsafeMutablePointer<AVFilterContext>?
    private let decoded: UnsafeMutablePointer<AVFrame>
    private let filtered: UnsafeMutablePointer<AVFrame>
    private let packet: UnsafeMutablePointer<AVPacket>

    init(input stream: UnsafeMutablePointer<AVStream>, deinterlace: Bool, globalHeader: Bool) throws {
        let parameters = stream.pointee.codecpar!
        guard let codec = avcodec_find_decoder(parameters.pointee.codec_id) else {
            throw BridgeError.unsupportedCodec(codecName(parameters.pointee.codec_id))
        }
        decoder = avcodec_alloc_context3(codec)
        try check(avcodec_parameters_to_context(decoder, parameters), "video decoder parameters")
        decoder.pointee.pkt_timebase = stream.pointee.time_base
        decoder.pointee.framerate = av_guess_frame_rate(nil, stream, nil)
        decoder.pointee.thread_count = 0
        try check(avcodec_open2(decoder, codec, nil), "open video decoder")
        self.deinterlace = deinterlace
        self.globalHeader = globalHeader
        decoded = av_frame_alloc()
        filtered = av_frame_alloc()
        packet = av_packet_alloc()
    }

    deinit {
        var decoder: UnsafeMutablePointer<AVCodecContext>? = decoder
        avcodec_free_context(&decoder)
        avcodec_free_context(&encoder)
        avfilter_graph_free(&graph)
        var decoded: UnsafeMutablePointer<AVFrame>? = decoded
        var filtered: UnsafeMutablePointer<AVFrame>? = filtered
        var packet: UnsafeMutablePointer<AVPacket>? = packet
        av_frame_free(&decoded)
        av_frame_free(&filtered)
        av_packet_free(&packet)
    }

    /// The encoder only exists once the first frame has been decoded, because its size comes from the stream.
    /// The output stream is set up then too, through `prepare`.
    func send(_ input: UnsafeMutablePointer<AVPacket>?,
              prepare: (UnsafeMutablePointer<AVCodecContext>) throws -> Void,
              emit: (UnsafeMutablePointer<AVPacket>) throws -> Void) throws {
        let sent = avcodec_send_packet(decoder, input)
        // Damaged packets are common on broadcast streams: drop them and carry on.
        if sent < 0, sent != AV.eof, input != nil { return }
        while true {
            let received = avcodec_receive_frame(decoder, decoded)
            if received == AV.again || received == AV.eof { break }
            if received < 0 { break }
            decoded.pointee.pts = decoded.pointee.best_effort_timestamp
            // US broadcasts carry closed captions alongside MPEG-2 frames. VideoToolbox's encoder fails on them
            // ("Unexpected end of SEI"), and nothing downstream shows them, so they're dropped here.
            av_frame_remove_side_data(decoded, AV_FRAME_DATA_A53_CC)
            if graph == nil { try setUp(for: decoded, prepare: prepare) }
            try check(av_buffersrc_add_frame_flags(source, decoded, 0), "filter video")
            try drainFilter(emit: emit)
        }
        if input == nil, graph != nil {
            _ = av_buffersrc_add_frame_flags(source, nil, 0)
            try drainFilter(emit: emit)
            try encode(nil, emit: emit)
        }
    }

    private func drainFilter(emit: (UnsafeMutablePointer<AVPacket>) throws -> Void) throws {
        while true {
            let received = av_buffersink_get_frame(sink, filtered)
            if received == AV.again || received == AV.eof { break }
            try check(received, "filter video")
            filtered.pointee.pict_type = AV_PICTURE_TYPE_NONE
            try encode(filtered, emit: emit)
            av_frame_unref(filtered)
        }
    }

    private func encode(_ frame: UnsafeMutablePointer<AVFrame>?, emit: (UnsafeMutablePointer<AVPacket>) throws -> Void) throws {
        guard let encoder = encoder?.pointee, let context = self.encoder else { return }
        let sent = avcodec_send_frame(context, frame)
        if sent < 0, sent != AV.eof { try check(sent, "encode video") }
        while true {
            let received = avcodec_receive_packet(context, packet)
            if received == AV.again || received == AV.eof { break }
            try check(received, "encode video")
            // VideoToolbox leaves durations unset; the HLS muxer needs them to time segments exactly.
            if packet.pointee.duration <= 0, encoder.framerate.num > 0 {
                packet.pointee.duration = av_rescale_q(1, av_inv_q(encoder.framerate), encoder.time_base)
            }
            try emit(packet)
            av_packet_unref(packet)
        }
    }

    private func setUp(for frame: UnsafeMutablePointer<AVFrame>,
                       prepare: (UnsafeMutablePointer<AVCodecContext>) throws -> Void) throws {
        graph = avfilter_graph_alloc()
        let timeBase = decoder.pointee.pkt_timebase
        let aspect = frame.pointee.sample_aspect_ratio.num > 0 ? frame.pointee.sample_aspect_ratio : AVRational(num: 1, den: 1)
        var sourceArgs = "video_size=\(frame.pointee.width)x\(frame.pointee.height):pix_fmt=\(frame.pointee.format)"
            + ":time_base=\(timeBase.num)/\(timeBase.den):pixel_aspect=\(aspect.num)/\(aspect.den)"
        // Without the frame rate, the filters' output reports none, and the encoder's keyframe interval and
        // level would be worked out for the wrong rate. Deinterlacing doubles it on the way.
        let sourceRate = decoder.pointee.framerate
        if sourceRate.num > 0, sourceRate.den > 0 { sourceArgs += ":frame_rate=\(sourceRate.num)/\(sourceRate.den)" }
        try check(avfilter_graph_create_filter(&source, avfilter_get_by_name("buffer"), "in", sourceArgs, nil, graph),
                  "video filter input")
        try check(avfilter_graph_create_filter(&sink, avfilter_get_by_name("buffersink"), "out", nil, nil, graph),
                  "video filter output")

        // One frame per field keeps sport and news motion smooth (50i becomes 50p).
        var chain = deinterlace ? "bwdif=mode=send_field:parity=auto:deint=interlaced," : ""
        // SD broadcasts use non-square pixels (704×480 at 40:33 is 16:9). VideoToolbox doesn't carry the pixel
        // aspect ratio into its output, so scale to square pixels instead of letting the picture look squashed.
        if aspect.num != aspect.den {
            chain += "scale=w=trunc(iw*sar/2)*2:h=ih,setsar=1,"
        }
        chain += "format=nv12"
        var outputs: UnsafeMutablePointer<AVFilterInOut>? = avfilter_inout_alloc()
        var inputs: UnsafeMutablePointer<AVFilterInOut>? = avfilter_inout_alloc()
        defer {
            avfilter_inout_free(&outputs)
            avfilter_inout_free(&inputs)
        }
        outputs!.pointee.name = av_strdup("in")
        outputs!.pointee.filter_ctx = source
        inputs!.pointee.name = av_strdup("out")
        inputs!.pointee.filter_ctx = sink
        try check(avfilter_graph_parse_ptr(graph, chain, &inputs, &outputs, nil), "video filters")
        try check(avfilter_graph_config(graph, nil), "configure video filters")

        guard let codec = avcodec_find_encoder_by_name("h264_videotoolbox") else {
            throw BridgeError.unsupportedCodec("h264_videotoolbox")
        }
        let encoder = avcodec_alloc_context3(codec)!
        self.encoder = encoder
        encoder.pointee.width = av_buffersink_get_w(sink)
        encoder.pointee.height = av_buffersink_get_h(sink)
        encoder.pointee.pix_fmt = AV_PIX_FMT_NV12
        encoder.pointee.sample_aspect_ratio = av_buffersink_get_sample_aspect_ratio(sink)
        encoder.pointee.time_base = av_buffersink_get_time_base(sink)
        var frameRate = av_buffersink_get_frame_rate(sink)
        if frameRate.num <= 0 { frameRate = AVRational(num: 25, den: 1) }
        encoder.pointee.framerate = frameRate
        // A keyframe every two seconds, so HLS segments can be cut there.
        encoder.pointee.gop_size = Int32((Double(frameRate.num) / Double(frameRate.den) * 2).rounded())
        encoder.pointee.max_b_frames = 0
        encoder.pointee.bit_rate = Self.bitRate(width: encoder.pointee.width, height: encoder.pointee.height,
                                                frameRate: frameRate)
        encoder.pointee.color_primaries = frame.pointee.color_primaries
        encoder.pointee.color_trc = frame.pointee.color_trc
        encoder.pointee.colorspace = frame.pointee.colorspace
        encoder.pointee.color_range = frame.pointee.color_range
        if globalHeader { encoder.pointee.flags |= AV_CODEC_FLAG_GLOBAL_HEADER }
        // `realtime` favours speed over squeezing bits; `allow_sw` lets the simulator and Macs without an
        // encoder for the size fall back to software.
        // VideoToolbox's automatic level can come out too low (level 3.0 for 480p at 60 fps), which Apple TV's
        // decoder refuses. Declare the level the picture actually needs.
        let level = Self.level(width: encoder.pointee.width, height: encoder.pointee.height, frameRate: frameRate)
        // Set on the encoder's own options: AVCodecContext has a generic `level` that would otherwise take it.
        try check(av_opt_set(encoder.pointee.priv_data, "level", level, 0), "H.264 level")
        var options = makeDictionary(["realtime": "1", "allow_sw": "1", "profile": "high", "a53cc": "0"])
        defer { av_dict_free(&options) }
        try check(avcodec_open2(encoder, codec, &options), "open H.264 encoder")
        try prepare(encoder)
    }

    /// The lowest H.264 level (as "4.2") whose frame size and macroblock rate limits fit the video.
    static func level(width: Int32, height: Int32, frameRate: AVRational) -> String {
        let fps = frameRate.den > 0 ? Double(frameRate.num) / Double(frameRate.den) : 25
        let macroblocks = Double((width + 15) / 16) * Double((height + 15) / 16)
        let rate = macroblocks * fps
        // (level, max macroblocks per frame, max macroblocks per second), from the H.264 spec, table A-1.
        let levels: [(String, Double, Double)] = [
            ("3.0", 1_620, 40_500), ("3.1", 3_600, 108_000), ("3.2", 5_120, 216_000),
            ("4.0", 8_192, 245_760), ("4.2", 8_704, 522_240), ("5.0", 22_080, 589_824),
            ("5.1", 36_864, 983_040), ("5.2", 36_864, 2_073_600),
        ]
        return levels.first { macroblocks <= $0.1 && rate <= $0.2 }?.0 ?? "5.2"
    }

    /// Roughly what broadcasters spend on H.264: about 0.1 bits per pixel per frame.
    static func bitRate(width: Int32, height: Int32, frameRate: AVRational) -> Int64 {
        let fps = frameRate.den > 0 ? Double(frameRate.num) / Double(frameRate.den) : 25
        let estimate = Double(width) * Double(height) * min(fps, 60) * 0.1
        return Int64(min(max(estimate, 1_500_000), 12_000_000))
    }
}
