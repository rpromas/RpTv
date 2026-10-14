// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreMedia
import CoreVideo
import FFmpeg
import Foundation
import VideoToolbox

/// A decoded picture, ready for the display layer.
struct VideoPicture {
    var pixelBuffer: CVPixelBuffer
    /// Presentation time and duration in seconds, on the player's timeline.
    var time: Double
    var duration: Double

    /// Wraps the picture for an `AVSampleBufferVideoRenderer`. `format` caches the description between pictures
    /// of the same kind.
    func sampleBuffer(format: inout CMVideoFormatDescription?) -> CMSampleBuffer? {
        if format == nil || !CMVideoFormatDescriptionMatchesImageBuffer(format!, imageBuffer: pixelBuffer) {
            format = nil
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer,
                                                         formatDescriptionOut: &format)
        }
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(seconds: duration, preferredTimescale: 90_000),
                                        presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 90_000),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        return sample
    }
}

/// Decodes one video stream: in hardware with VideoToolbox where the device can (H.264, HEVC, VP9, AV1 and, on
/// Macs, MPEG-2), in software otherwise.
final class VideoDecoder {
    let context: UnsafeMutablePointer<AVCodecContext>
    private var device: UnsafeMutablePointer<AVBufferRef>?
    private let frame: UnsafeMutablePointer<AVFrame>

    init(stream: StreamParameters) throws {
        let parameters = stream.parameters
        guard let codec = avcodec_find_decoder(parameters.pointee.codec_id) else {
            throw PlayerError.unsupportedCodec(codecName(parameters.pointee.codec_id))
        }
        context = avcodec_alloc_context3(codec)
        frame = av_frame_alloc()
        try check(avcodec_parameters_to_context(context, parameters), "video decoder parameters")
        context.pointee.pkt_timebase = stream.timeBase
        context.pointee.framerate = stream.frameRate
        context.pointee.thread_count = 0
        if av_hwdevice_ctx_create(&device, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0) >= 0 {
            context.pointee.hw_device_ctx = av_buffer_ref(device)
            // VideoToolbox when it's offered. If it then can't open the stream (MPEG-2 on iPhone), FFmpeg asks
            // again without it, and the first software format is the one to take.
            context.pointee.get_format = { _, formats in
                guard var format = formats else { return AV_PIX_FMT_NONE }
                var software = AV_PIX_FMT_NONE
                while format.pointee != AV_PIX_FMT_NONE {
                    if format.pointee == AV_PIX_FMT_VIDEOTOOLBOX { return AV_PIX_FMT_VIDEOTOOLBOX }
                    if software == AV_PIX_FMT_NONE,
                       let descriptor = av_pix_fmt_desc_get(format.pointee),
                       descriptor.pointee.flags & UInt64(AV_PIX_FMT_FLAG_HWACCEL) == 0 {
                        software = format.pointee
                    }
                    format += 1
                }
                return software
            }
        }
        try check(avcodec_open2(context, codec, nil), "open video decoder")
    }

    deinit {
        var context: UnsafeMutablePointer<AVCodecContext>? = context
        avcodec_free_context(&context)
        av_buffer_unref(&device)
        var frame: UnsafeMutablePointer<AVFrame>? = frame
        av_frame_free(&frame)
    }

    /// Sends a packet (or `nil` to drain at the end) and hands each decoded frame to `emit`. Damaged packets are
    /// skipped: broadcast streams have plenty.
    func decode(_ packet: UnsafeMutablePointer<AVPacket>?, emit: (UnsafeMutablePointer<AVFrame>) -> Void) {
        let sent = avcodec_send_packet(context, packet)
        if sent < 0, sent != AV.eof, packet != nil { return }
        while avcodec_receive_frame(context, frame) >= 0 {
            emit(frame)
            av_frame_unref(frame)
        }
    }

    func flush() {
        avcodec_flush_buffers(context)
    }
}

/// Turns decoded frames into pixel buffers the display layer takes.
///
/// Hardware frames already are pixel buffers and pass through untouched. Software frames are copied into pooled
/// IOSurface buffers. Interlaced video is deinterlaced with `bwdif` (one picture per field, so 50i plays as 50p),
/// and video with non-square pixels (SD broadcasts, 1440×1080 HD) is scaled to square pixels on the GPU, so the
/// layer, Picture in Picture and the subtitles all see the real shape.
final class VideoConverter {
    private let timeBase: AVRational
    private let frameRate: AVRational
    /// Turned on by the first interlaced frame and kept on, so a stream doesn't flip between two paths.
    private(set) var deinterlaces: Bool

    private var graph: UnsafeMutablePointer<AVFilterGraph>?
    private var source: UnsafeMutablePointer<AVFilterContext>?
    private var sink: UnsafeMutablePointer<AVFilterContext>?
    private var graphKey: GraphKey?
    private var pool: CVPixelBufferPool?
    private var poolKey: PoolKey?
    private var scaler: VTPixelTransferSession?
    private var scalePool: CVPixelBufferPool?
    private var scalePoolKey: PoolKey?
    private let software: UnsafeMutablePointer<AVFrame>
    private let filtered: UnsafeMutablePointer<AVFrame>
    private var lastTime: Double?

    private struct GraphKey: Equatable {
        var width: Int32
        var height: Int32
        var format: Int32
        var deinterlace: Bool
    }

    private struct PoolKey: Equatable {
        var width: Int
        var height: Int
        var format: OSType
    }

    init(timeBase: AVRational, frameRate: AVRational, interlaced: Bool) {
        self.timeBase = timeBase
        self.frameRate = frameRate
        deinterlaces = interlaced
        software = av_frame_alloc()
        filtered = av_frame_alloc()
    }

    deinit {
        avfilter_graph_free(&graph)
        var software: UnsafeMutablePointer<AVFrame>? = software
        var filtered: UnsafeMutablePointer<AVFrame>? = filtered
        av_frame_free(&software)
        av_frame_free(&filtered)
    }

    /// Forgets timing and buffered fields, after a seek.
    func reset() {
        lastTime = nil
        graphKey = nil
        avfilter_graph_free(&graph)
    }

    /// The time a frame is shown at, in seconds, or `nil` when it has no timestamp to go by.
    func time(of frame: UnsafeMutablePointer<AVFrame>) -> Double? {
        let timestamp = frame.pointee.best_effort_timestamp != AV.noPTS ? frame.pointee.best_effort_timestamp : frame.pointee.pts
        return timestamp != AV.noPTS ? Double(timestamp) * timeBase.seconds : nil
    }

    func convert(_ frame: UnsafeMutablePointer<AVFrame>, emit: (VideoPicture) -> Void) throws {
        if frame.pointee.flags & AV_FRAME_FLAG_INTERLACED != 0 { deinterlaces = true }

        if frame.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue, !deinterlaces {
            guard let raw = frame.pointee.data.3 else { return }
            let buffer = Unmanaged<CVPixelBuffer>.fromOpaque(UnsafeRawPointer(raw)).takeUnretainedValue()
            let time = time(of: frame) ?? lastTime.map { $0 + defaultDuration } ?? 0
            lastTime = time
            emitPicture(buffer, aspect: frame.pointee.sample_aspect_ratio, time: time,
                        duration: duration(of: frame, in: timeBase), emit: emit)
            return
        }

        var input = frame
        if frame.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue {
            // Interlaced video decoded in hardware: bring it to memory for the deinterlacer.
            av_frame_unref(software)
            try check(av_hwframe_transfer_data(software, frame, 0), "read decoded picture")
            av_frame_copy_props(software, frame)
            input = software
        }
        try filter(input, emit: emit)
    }

    // MARK: - Software frames

    private func filter(_ frame: UnsafeMutablePointer<AVFrame>, emit: (VideoPicture) -> Void) throws {
        let key = GraphKey(width: frame.pointee.width, height: frame.pointee.height, format: frame.pointee.format,
                           deinterlace: deinterlaces)
        if key != graphKey {
            try makeGraph(for: frame, key: key)
        }
        try check(av_buffersrc_add_frame_flags(source, frame, Int32(AV_BUFFERSRC_FLAG_KEEP_REF)), "filter video")
        let sinkTimeBase = av_buffersink_get_time_base(sink)
        while av_buffersink_get_frame(sink, filtered) >= 0 {
            defer { av_frame_unref(filtered) }
            let timestamp = filtered.pointee.pts
            let time = timestamp != AV.noPTS ? Double(timestamp) * sinkTimeBase.seconds
                : lastTime.map { $0 + defaultDuration } ?? 0
            lastTime = time
            guard let buffer = try copy(filtered) else { continue }
            emitPicture(buffer, aspect: filtered.pointee.sample_aspect_ratio, time: time,
                        duration: duration(of: filtered, in: sinkTimeBase), emit: emit)
        }
    }

    private func makeGraph(for frame: UnsafeMutablePointer<AVFrame>, key: GraphKey) throws {
        avfilter_graph_free(&graph)
        graphKey = nil
        graph = avfilter_graph_alloc()
        let aspect = frame.pointee.sample_aspect_ratio.num > 0 ? frame.pointee.sample_aspect_ratio : AVRational(num: 1, den: 1)
        var arguments = "video_size=\(key.width)x\(key.height):pix_fmt=\(key.format)"
            + ":time_base=\(timeBase.num)/\(timeBase.den):pixel_aspect=\(aspect.num)/\(aspect.den)"
        if frameRate.num > 0, frameRate.den > 0 { arguments += ":frame_rate=\(frameRate.num)/\(frameRate.den)" }
        try check(avfilter_graph_create_filter(&source, avfilter_get_by_name("buffer"), "in", arguments, nil, graph),
                  "video filter input")
        try check(avfilter_graph_create_filter(&sink, avfilter_get_by_name("buffersink"), "out", nil, nil, graph),
                  "video filter output")

        let highDepth = (av_pix_fmt_desc_get(AVPixelFormat(key.format))?.pointee.comp.0.depth ?? 8) > 8
        var chain = key.deinterlace ? "bwdif=mode=send_field:parity=auto:deint=interlaced," : ""
        chain += highDepth ? "format=p010le" : "format=nv12"
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
        graphKey = key
    }

    /// Copies an NV12 or P010 frame into a pooled pixel buffer, with its colour attachments.
    private func copy(_ frame: UnsafeMutablePointer<AVFrame>) throws -> CVPixelBuffer? {
        let width = Int(frame.pointee.width), height = Int(frame.pointee.height)
        let pixelFormat = AVPixelFormat(frame.pointee.format)
        let format = av_map_videotoolbox_format_from_pixfmt2(pixelFormat, frame.pointee.color_range == AVCOL_RANGE_JPEG)
        guard format != 0, let buffer = pooledBuffer(PoolKey(width: width, height: height, format: format), pool: &pool,
                                                     key: &poolKey) else { return nil }
        let bytesPerSample = pixelFormat == AV_PIX_FMT_P010LE ? 2 : 1
        CVPixelBufferLockBaseAddress(buffer, [])
        let data = planes(of: frame)
        for plane in 0..<2 {
            guard let destination = CVPixelBufferGetBaseAddressOfPlane(buffer, plane), let source = data[plane].0 else { continue }
            let rows = plane == 0 ? height : (height + 1) / 2
            let rowBytes = (plane == 0 ? width : (width + 1) / 2 * 2) * bytesPerSample
            av_image_copy_plane(destination.assumingMemoryBound(to: UInt8.self),
                                Int32(CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)),
                                source, data[plane].1, Int32(rowBytes), Int32(rows))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        // Untagged video is usual for SD broadcasts: assume what its size implies, as TVs do.
        let standardDefinition = height <= 576
        if frame.pointee.colorspace == AVCOL_SPC_UNSPECIFIED {
            frame.pointee.colorspace = standardDefinition ? (height == 576 ? AVCOL_SPC_BT470BG : AVCOL_SPC_SMPTE170M) : AVCOL_SPC_BT709
        }
        if frame.pointee.color_primaries == AVCOL_PRI_UNSPECIFIED {
            frame.pointee.color_primaries = standardDefinition ? (height == 576 ? AVCOL_PRI_BT470BG : AVCOL_PRI_SMPTE170M) : AVCOL_PRI_BT709
        }
        if frame.pointee.color_trc == AVCOL_TRC_UNSPECIFIED {
            frame.pointee.color_trc = AVCOL_TRC_BT709
        }
        av_vt_pixbuf_set_attachments(nil, buffer, frame)
        return buffer
    }

    private func planes(of frame: UnsafeMutablePointer<AVFrame>) -> [(UnsafeMutablePointer<UInt8>?, Int32)] {
        [(frame.pointee.data.0, frame.pointee.linesize.0), (frame.pointee.data.1, frame.pointee.linesize.1)]
    }

    // MARK: - Output

    private func emitPicture(_ buffer: CVPixelBuffer, aspect: AVRational, time: Double, duration: Double,
                             emit: (VideoPicture) -> Void) {
        var output = buffer
        if aspect.num > 0, aspect.den > 0, aspect.num != aspect.den, let scaled = squarePixels(buffer, aspect: aspect) {
            output = scaled
        }
        emit(VideoPicture(pixelBuffer: output, time: time, duration: duration))
    }

    /// Scales `buffer` horizontally so its pixels are square, with VideoToolbox.
    private func squarePixels(_ buffer: CVPixelBuffer, aspect: AVRational) -> CVPixelBuffer? {
        let height = CVPixelBufferGetHeight(buffer)
        let exact = Double(CVPixelBufferGetWidth(buffer)) * Double(aspect.num) / Double(aspect.den)
        let width = min(max(Int((exact / 2).rounded()) * 2, 16), 8192)
        let key = PoolKey(width: width, height: height, format: CVPixelBufferGetPixelFormatType(buffer))
        if scaler == nil { VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &scaler) }
        guard let scaler, let output = pooledBuffer(key, pool: &scalePool, key: &scalePoolKey),
              VTPixelTransferSessionTransferImage(scaler, from: buffer, to: output) == noErr else { return nil }
        CVBufferPropagateAttachments(buffer, output)
        CVBufferRemoveAttachment(output, kCVImageBufferPixelAspectRatioKey)
        return output
    }

    private func pooledBuffer(_ wanted: PoolKey, pool: inout CVPixelBufferPool?, key: inout PoolKey?) -> CVPixelBuffer? {
        if key != wanted {
            pool = nil
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: wanted.format,
                kCVPixelBufferWidthKey: wanted.width,
                kCVPixelBufferHeightKey: wanted.height,
                kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
            key = wanted
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }

    private var defaultDuration: Double {
        let rate = frameRate.num > 0 && frameRate.den > 0 ? Double(frameRate.num) / Double(frameRate.den) : 25
        return 1 / (deinterlaces ? rate * 2 : rate)
    }

    private func duration(of frame: UnsafeMutablePointer<AVFrame>, in timeBase: AVRational) -> Double {
        frame.pointee.duration > 0 ? Double(frame.pointee.duration) * timeBase.seconds : defaultDuration
    }
}
