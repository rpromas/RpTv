// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AudioToolbox
import CoreMedia
import FFmpeg
import Foundation

/// Decodes one audio stream to interleaved 32-bit float sample buffers for an `AVSampleBufferAudioRenderer`.
/// Surround keeps its channels; layouts Core Audio can't describe become stereo.
final class AudioDecoder {
    private let context: UnsafeMutablePointer<AVCodecContext>
    private let frame: UnsafeMutablePointer<AVFrame>
    private var resampler: OpaquePointer?
    private var outputLayout = AVChannelLayout()
    private var inputKey: InputKey?
    private var format: CMAudioFormatDescription?
    private var sampleRate: Int32 = 0
    /// Where the next sample goes, in samples. Keeps the output gapless when timestamps wobble.
    private var nextSample: Int64?

    private struct InputKey: Equatable {
        var format: Int32
        var sampleRate: Int32
        var channels: Int32
        var mask: UInt64
    }

    init(stream: StreamParameters) throws {
        let parameters = stream.parameters
        guard let codec = avcodec_find_decoder(parameters.pointee.codec_id) else {
            throw PlayerError.unsupportedCodec(codecName(parameters.pointee.codec_id))
        }
        context = avcodec_alloc_context3(codec)
        frame = av_frame_alloc()
        try check(avcodec_parameters_to_context(context, parameters), "audio decoder parameters")
        context.pointee.pkt_timebase = stream.timeBase
        try check(avcodec_open2(context, codec, nil), "open audio decoder")
    }

    deinit {
        var context: UnsafeMutablePointer<AVCodecContext>? = context
        avcodec_free_context(&context)
        var frame: UnsafeMutablePointer<AVFrame>? = frame
        av_frame_free(&frame)
        swr_free(&resampler)
        av_channel_layout_uninit(&outputLayout)
    }

    func flush() {
        avcodec_flush_buffers(context)
        nextSample = nil
    }

    /// Sends a packet (or `nil` to drain at the end) and hands `emit` a sample buffer per decoded frame.
    /// Samples before `trimBefore` seconds are cut, so playback starts exactly where it was asked to.
    func decode(_ packet: UnsafeMutablePointer<AVPacket>?, trimBefore: Double?, emit: (CMSampleBuffer) -> Void) {
        let sent = avcodec_send_packet(context, packet)
        if sent < 0, sent != AV.eof, packet != nil { return }
        while avcodec_receive_frame(context, frame) >= 0 {
            if let buffer = convert(frame, trimBefore: trimBefore) { emit(buffer) }
            av_frame_unref(frame)
        }
    }

    private func convert(_ frame: UnsafeMutablePointer<AVFrame>, trimBefore: Double?) -> CMSampleBuffer? {
        let key = InputKey(format: frame.pointee.format, sampleRate: frame.pointee.sample_rate,
                           channels: frame.pointee.ch_layout.nb_channels,
                           mask: frame.pointee.ch_layout.order == AV_CHANNEL_ORDER_NATIVE ? frame.pointee.ch_layout.u.mask : 0)
        if key != inputKey {
            guard key.sampleRate > 0, key.channels > 0, setUp(for: frame) else { return nil }
            inputKey = key
            nextSample = nil
        }

        // Timestamps within 100 ms of where the last frame ended are rounding noise or jitter: stay gapless.
        let timestamp = frame.pointee.best_effort_timestamp != AV.noPTS ? frame.pointee.best_effort_timestamp : frame.pointee.pts
        if timestamp != AV.noPTS {
            let sample = Int64((Double(timestamp) * context.pointee.pkt_timebase.seconds * Double(sampleRate)).rounded())
            if nextSample == nil || abs(sample - nextSample!) > Int64(sampleRate / 10) { nextSample = sample }
        }
        var start = nextSample ?? 0
        let count = Int(frame.pointee.nb_samples)
        nextSample = start + Int64(count)

        let channels = Int(outputLayout.nb_channels)
        var samples = [Float](repeating: 0, count: count * channels)
        let converted = samples.withUnsafeMutableBytes { output -> Int32 in
            var outputPlanes: [UnsafeMutablePointer<UInt8>?] = [output.baseAddress!.assumingMemoryBound(to: UInt8.self)]
            let input = UnsafeMutableRawPointer(frame.pointee.extended_data)!.assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
            return swr_convert(resampler, &outputPlanes, Int32(count), input, frame.pointee.nb_samples)
        }
        guard converted > 0 else { return nil }
        var skip = 0
        if let trimBefore {
            let first = Int64((trimBefore * Double(sampleRate)).rounded(.up))
            if start + Int64(converted) <= first { return nil }
            if start < first { skip = Int(first - start) }
        }
        start += Int64(skip)
        let kept = Int(converted) - skip
        return samples.withUnsafeBytes { bytes in
            let offset = skip * channels * MemoryLayout<Float>.size
            return makeSampleBuffer(bytes.baseAddress! + offset, count: kept, channels: channels, start: start)
        }
    }

    private func setUp(for frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        swr_free(&resampler)
        av_channel_layout_uninit(&outputLayout)
        format = nil
        sampleRate = frame.pointee.sample_rate

        var layout = Self.coreAudioLayout(for: frame.pointee.ch_layout)
        if layout != nil {
            av_channel_layout_copy(&outputLayout, &frame.pointee.ch_layout)
        } else {
            // Unknown order with one or two channels is mono or stereo; anything else is mixed down to stereo.
            let channels = frame.pointee.ch_layout.nb_channels
            av_channel_layout_default(&outputLayout, channels == 1 ? 1 : 2)
            layout = Self.coreAudioLayout(for: outputLayout)
        }
        guard let layout else { return false }

        var inputLayout = AVChannelLayout()
        defer { av_channel_layout_uninit(&inputLayout) }
        if frame.pointee.ch_layout.order == AV_CHANNEL_ORDER_UNSPEC {
            av_channel_layout_default(&inputLayout, frame.pointee.ch_layout.nb_channels)
        } else {
            av_channel_layout_copy(&inputLayout, &frame.pointee.ch_layout)
        }
        guard swr_alloc_set_opts2(&resampler, &outputLayout, AV_SAMPLE_FMT_FLT, sampleRate,
                                  &inputLayout, AVSampleFormat(frame.pointee.format), sampleRate, 0, nil) >= 0,
              swr_init(resampler) >= 0 else { return false }

        let channels = UInt32(outputLayout.nb_channels)
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
        layout.withUnsafeBytes { bytes in
            _ = CMAudioFormatDescriptionCreate(
                allocator: nil, asbd: &description, layoutSize: bytes.count,
                layout: bytes.baseAddress!.assumingMemoryBound(to: AudioChannelLayout.self),
                magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        }
        return format != nil
    }

    private func makeSampleBuffer(_ data: UnsafeRawPointer, count: Int, channels: Int, start: Int64) -> CMSampleBuffer? {
        guard let format, count > 0 else { return nil }
        let length = count * channels * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block,
              CMBlockBufferReplaceDataBytes(with: data, blockBuffer: block, offsetIntoDestination: 0,
                                            dataLength: length) == noErr else { return nil }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: count,
            presentationTimeStamp: CMTime(value: start, timescale: sampleRate), packetDescriptions: nil,
            sampleBufferOut: &sample)
        return sample
    }

    /// The Core Audio description of an FFmpeg channel layout, as the bytes of an `AudioChannelLayout`, or `nil`
    /// when it has channels Core Audio has no label for.
    static func coreAudioLayout(for layout: AVChannelLayout) -> Data? {
        guard layout.order == AV_CHANNEL_ORDER_NATIVE, (1...8).contains(layout.nb_channels) else { return nil }
        var copy = layout
        let channels = (0..<layout.nb_channels).map { av_channel_layout_channel_from_index(&copy, UInt32($0)) }
        let hasSides = channels.contains(AV_CHAN_SIDE_LEFT)

        func tagged(_ tag: AudioChannelLayoutTag) -> Data {
            var value = AudioChannelLayout()
            value.mChannelLayoutTag = tag
            return Data(bytes: &value, count: MemoryLayout<AudioChannelLayout>.size)
        }
        if channels == [AV_CHAN_FRONT_CENTER] { return tagged(kAudioChannelLayoutTag_Mono) }
        if channels == [AV_CHAN_FRONT_LEFT, AV_CHAN_FRONT_RIGHT] { return tagged(kAudioChannelLayoutTag_Stereo) }

        var labels: [AudioChannelLabel] = []
        for channel in channels {
            let label: AudioChannelLabel
            switch channel {
            case AV_CHAN_FRONT_LEFT: label = kAudioChannelLabel_Left
            case AV_CHAN_FRONT_RIGHT: label = kAudioChannelLabel_Right
            case AV_CHAN_FRONT_CENTER: label = kAudioChannelLabel_Center
            case AV_CHAN_LOW_FREQUENCY: label = kAudioChannelLabel_LFEScreen
            // 5.1 has its surrounds at the back or the sides depending on the source; 7.1 has both.
            case AV_CHAN_BACK_LEFT: label = hasSides ? kAudioChannelLabel_RearSurroundLeft : kAudioChannelLabel_LeftSurround
            case AV_CHAN_BACK_RIGHT: label = hasSides ? kAudioChannelLabel_RearSurroundRight : kAudioChannelLabel_RightSurround
            case AV_CHAN_SIDE_LEFT: label = kAudioChannelLabel_LeftSurround
            case AV_CHAN_SIDE_RIGHT: label = kAudioChannelLabel_RightSurround
            case AV_CHAN_BACK_CENTER: label = kAudioChannelLabel_CenterSurround
            case AV_CHAN_FRONT_LEFT_OF_CENTER: label = kAudioChannelLabel_LeftCenter
            case AV_CHAN_FRONT_RIGHT_OF_CENTER: label = kAudioChannelLabel_RightCenter
            default: return nil
            }
            labels.append(label)
        }

        let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
        let size = offset + labels.count * MemoryLayout<AudioChannelDescription>.stride
        var data = Data(count: max(size, MemoryLayout<AudioChannelLayout>.size))
        data.withUnsafeMutableBytes { bytes in
            let header = bytes.baseAddress!.assumingMemoryBound(to: AudioChannelLayout.self)
            header.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
            header.pointee.mChannelBitmap = []
            header.pointee.mNumberChannelDescriptions = UInt32(labels.count)
            let descriptions = (bytes.baseAddress! + offset).assumingMemoryBound(to: AudioChannelDescription.self)
            for (index, label) in labels.enumerated() {
                descriptions[index] = AudioChannelDescription(mChannelLabel: label, mChannelFlags: [],
                                                              mCoordinates: (0, 0, 0))
            }
        }
        return data
    }
}
