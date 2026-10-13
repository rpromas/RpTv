// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import FFmpeg
import Foundation

/// Decodes an audio stream Apple can't play (MP2, LATM AAC, Opus, …) and re-encodes it as AAC, keeping its
/// timestamps lined up with the video it's muxed with.
final class AudioTranscoder {
    let encoder: UnsafeMutablePointer<AVCodecContext>
    private let decoder: UnsafeMutablePointer<AVCodecContext>
    private var resampler: OpaquePointer?
    private let fifo: OpaquePointer
    private let frameSize: Int32
    private let decoded: UnsafeMutablePointer<AVFrame>
    private let packet: UnsafeMutablePointer<AVPacket>
    /// The timestamp of the next sample to leave the FIFO, in the encoder's time base (1 / sample rate).
    private var nextPTS: Int64?

    init(input stream: UnsafeMutablePointer<AVStream>, globalHeader: Bool) throws {
        let parameters = stream.pointee.codecpar!
        guard let decoderCodec = avcodec_find_decoder(parameters.pointee.codec_id) else {
            throw BridgeError.unsupportedCodec(codecName(parameters.pointee.codec_id))
        }
        decoder = avcodec_alloc_context3(decoderCodec)
        try check(avcodec_parameters_to_context(decoder, parameters), "audio decoder parameters")
        decoder.pointee.pkt_timebase = stream.pointee.time_base
        try check(avcodec_open2(decoder, decoderCodec, nil), "open audio decoder")

        // Apple's AAC encoder sounds better than FFmpeg's; FFmpeg's is there if AudioToolbox isn't.
        guard let encoderCodec = avcodec_find_encoder_by_name("aac_at") ?? avcodec_find_encoder(AV_CODEC_ID_AAC) else {
            throw BridgeError.unsupportedCodec("aac encoder")
        }
        encoder = avcodec_alloc_context3(encoderCodec)
        let sampleRate = decoder.pointee.sample_rate > 0 ? decoder.pointee.sample_rate : 48000
        encoder.pointee.sample_rate = sampleRate
        encoder.pointee.time_base = AVRational(num: 1, den: sampleRate)
        // Up to 5.1 passes through; anything wider (or unknown) becomes stereo.
        let channels = decoder.pointee.ch_layout.nb_channels
        av_channel_layout_default(&encoder.pointee.ch_layout, channels > 0 && channels <= 6 ? channels : 2)
        encoder.pointee.sample_fmt = Self.preferredSampleFormat(encoder, encoderCodec)
        encoder.pointee.bit_rate = encoder.pointee.ch_layout.nb_channels > 2 ? 384_000 : 160_000
        if globalHeader { encoder.pointee.flags |= AV_CODEC_FLAG_GLOBAL_HEADER }
        try check(avcodec_open2(encoder, encoderCodec, nil), "open AAC encoder")

        frameSize = encoder.pointee.frame_size > 0 ? encoder.pointee.frame_size : 1024
        fifo = av_audio_fifo_alloc(encoder.pointee.sample_fmt, encoder.pointee.ch_layout.nb_channels, frameSize)
        decoded = av_frame_alloc()
        packet = av_packet_alloc()
    }

    deinit {
        var decoder: UnsafeMutablePointer<AVCodecContext>? = decoder
        var encoder: UnsafeMutablePointer<AVCodecContext>? = encoder
        var decoded: UnsafeMutablePointer<AVFrame>? = decoded
        var packet: UnsafeMutablePointer<AVPacket>? = packet
        avcodec_free_context(&decoder)
        avcodec_free_context(&encoder)
        av_frame_free(&decoded)
        av_packet_free(&packet)
        av_audio_fifo_free(fifo)
        swr_free(&resampler)
    }

    /// Feeds one source packet; `emit` receives each AAC packet, in the encoder's time base.
    func send(_ input: UnsafeMutablePointer<AVPacket>?, emit: (UnsafeMutablePointer<AVPacket>) throws -> Void) throws {
        let sent = avcodec_send_packet(decoder, input)
        // Broadcast audio has the odd corrupt frame: skip it rather than stop the stream.
        if sent < 0, sent != AV.eof, input != nil { return }
        while true {
            let received = avcodec_receive_frame(decoder, decoded)
            if received == AV.again || received == AV.eof { break }
            if received < 0 { break }
            try resample(decoded)
            av_frame_unref(decoded)
            try drainFIFO(final: false, emit: emit)
        }
        if input == nil {
            try drainFIFO(final: true, emit: emit)
            try encode(nil, emit: emit)
        }
    }

    private func resample(_ frame: UnsafeMutablePointer<AVFrame>) throws {
        if resampler == nil {
            try check(swr_alloc_set_opts2(&resampler,
                                          &encoder.pointee.ch_layout, encoder.pointee.sample_fmt, encoder.pointee.sample_rate,
                                          &frame.pointee.ch_layout, AVSampleFormat(frame.pointee.format), frame.pointee.sample_rate,
                                          0, nil), "audio resampler")
            try check(swr_init(resampler), "start audio resampler")
        }

        let pts = frame.pointee.best_effort_timestamp != AV.noPTS ? frame.pointee.best_effort_timestamp : frame.pointee.pts
        if pts != AV.noPTS {
            let framePTS = av_rescale_q(pts, decoder.pointee.pkt_timebase, encoder.pointee.time_base)
            // What's waiting in the FIFO comes before this frame.
            let expected = framePTS - Int64(av_audio_fifo_size(fifo))
            // Start, or jump back into line after a gap or a timestamp reset in the source.
            if nextPTS == nil || abs(expected - nextPTS!) > Int64(encoder.pointee.sample_rate / 2) {
                nextPTS = expected
            }
        }

        let capacity = swr_get_out_samples(resampler, frame.pointee.nb_samples)
        guard capacity > 0 else { return }
        var output: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?
        try check(av_samples_alloc_array_and_samples(&output, nil, encoder.pointee.ch_layout.nb_channels, capacity,
                                                     encoder.pointee.sample_fmt, 0), "audio buffer")
        defer {
            av_freep(UnsafeMutableRawPointer(output))
            av_freep(&output)
        }
        let inputData = UnsafeMutableRawPointer(frame.pointee.extended_data)!
            .assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
        let converted = try check(swr_convert(resampler, output, capacity, inputData, frame.pointee.nb_samples),
                                  "resample audio")
        _ = av_audio_fifo_write(fifo, UnsafeMutableRawPointer(output)!.assumingMemoryBound(to: UnsafeMutableRawPointer?.self),
                                converted)
    }

    private func drainFIFO(final: Bool, emit: (UnsafeMutablePointer<AVPacket>) throws -> Void) throws {
        while av_audio_fifo_size(fifo) >= frameSize || (final && av_audio_fifo_size(fifo) > 0) {
            let count = min(frameSize, av_audio_fifo_size(fifo))
            var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
            defer { av_frame_free(&frame) }
            guard let frame else { return }
            frame.pointee.nb_samples = count
            frame.pointee.format = encoder.pointee.sample_fmt.rawValue
            frame.pointee.sample_rate = encoder.pointee.sample_rate
            av_channel_layout_copy(&frame.pointee.ch_layout, &encoder.pointee.ch_layout)
            try check(av_frame_get_buffer(frame, 0), "audio frame")
            let data = UnsafeMutableRawPointer(frame.pointee.extended_data)!
                .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
            _ = av_audio_fifo_read(fifo, data, count)
            frame.pointee.pts = nextPTS ?? 0
            nextPTS = (nextPTS ?? 0) + Int64(count)
            try encode(frame, emit: emit)
        }
    }

    private func encode(_ frame: UnsafeMutablePointer<AVFrame>?, emit: (UnsafeMutablePointer<AVPacket>) throws -> Void) throws {
        let sent = avcodec_send_frame(encoder, frame)
        if sent < 0, sent != AV.eof { try check(sent, "encode audio") }
        while true {
            let received = avcodec_receive_packet(encoder, packet)
            if received == AV.again || received == AV.eof { break }
            try check(received, "encode audio")
            try emit(packet)
            av_packet_unref(packet)
        }
    }

    /// The encoder's first supported sample format, or planar float.
    private static func preferredSampleFormat(_ context: UnsafeMutablePointer<AVCodecContext>,
                                              _ codec: UnsafePointer<AVCodec>) -> AVSampleFormat {
        var formats: UnsafeRawPointer?
        var count: Int32 = 0
        if avcodec_get_supported_config(context, codec, AV_CODEC_CONFIG_SAMPLE_FORMAT, 0, &formats, &count) >= 0,
           let formats, count > 0 {
            return formats.assumingMemoryBound(to: AVSampleFormat.self).pointee
        }
        return AV_SAMPLE_FMT_FLTP
    }
}
