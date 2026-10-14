// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import FFmpeg
import Foundation
import OSLog
import Synchronization

private let log = Logger(subsystem: "app.rptv.RpTv", category: "StreamBridge")

public enum BridgeError: Error, LocalizedError, Sendable, Equatable {
    case noPlayableStreams
    case unsupportedCodec(String)
    /// A live source stopped sending and didn't come back after reconnecting.
    case sourceStopped

    public var errorDescription: String? {
        switch self {
        case .noPlayableStreams: "The stream has no audio or video."
        case .unsupportedCodec(let name): "The stream uses \(name), which can't be converted."
        case .sourceStopped: "The channel stopped sending video."
        }
    }
}

/// A stream to bridge.
public struct BridgeSource: Sendable {
    public var url: URL
    /// HTTP headers to send, such as `User-Agent` and `Referer`.
    public var headers: [String: String]
    /// Live streams keep a short sliding playlist; finite ones keep every segment so the whole thing is seekable.
    public var isLive: Bool

    public init(url: URL, headers: [String: String] = [:], isLive: Bool) {
        self.url = url
        self.headers = headers
        self.isLive = isLive
    }
}

/// Reads a stream with FFmpeg and writes it into `directory` as HLS (`index.m3u8` plus segments), copying what
/// Apple's players decode and re-encoding the rest. Runs on its own thread until cancelled or the source ends.
public final class HLSBridge: Sendable {
    public enum Event: Sendable {
        /// The playlist has enough segments for AVPlayer to start.
        case ready(BridgePlan)
        case failed(String)
        /// A finite source has been written completely.
        case finished
    }

    public static let playlistName = "index.m3u8"

    public let source: BridgeSource
    public let directory: URL
    private let cancelled = CancellationFlag()

    public init(source: BridgeSource, directory: URL) {
        self.source = source
        self.directory = directory
    }

    /// Starts converting. `onEvent` is called on the bridge's thread.
    public func start(onEvent: @escaping @Sendable (Event) -> Void) {
        // FFmpeg logs every damaged broadcast packet; only real errors are worth the console.
        av_log_set_level(AV_LOG_ERROR)
        let thread = Thread { [self] in
            do {
                let pipeline = try Pipeline(source: source, directory: directory, cancelled: cancelled, onEvent: onEvent)
                try pipeline.run()
                if !cancelled.isSet { onEvent(.finished) }
            } catch {
                if !cancelled.isSet { onEvent(.failed(error.localizedDescription)) }
            }
        }
        thread.name = "StreamBridge"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Stops reading as soon as FFmpeg returns control, including from a blocked network read.
    public func cancel() {
        cancelled.set()
    }
}

/// Shared between the bridge and its thread; FFmpeg's blocking calls poll it through their interrupt callback.
final class CancellationFlag: Sendable {
    private let value = Atomic<Bool>(false)

    var isSet: Bool { value.load(ordering: .relaxed) }

    func set() {
        value.store(true, ordering: .relaxed)
    }
}

/// One run of the bridge. Not thread-safe: lives on the bridge's thread.
private final class Pipeline {
    private let source: BridgeSource
    private let directory: URL
    private let cancelled: CancellationFlag
    private let onEvent: @Sendable (HLSBridge.Event) -> Void

    private var input: UnsafeMutablePointer<AVFormatContext>?
    private var output: UnsafeMutablePointer<AVFormatContext>?
    private var videoIndex: Int32 = -1
    private var audioIndex: Int32 = -1
    private var videoOut: UnsafeMutablePointer<AVStream>?
    private var audioOut: UnsafeMutablePointer<AVStream>?
    private var videoTranscoder: VideoTranscoder?
    private var audioTranscoder: AudioTranscoder?
    /// Rewrites copied AAC from ADTS framing (how transport streams carry it) to the form MP4 needs.
    private var audioFilter: UnsafeMutablePointer<AVBSFContext>?
    private var plan: BridgePlan!
    private var headerWritten = false
    /// Packets that arrived before the header could be written (the video encoder's size isn't known until its
    /// first frame), each with its source time base.
    private var pending: [(UnsafeMutablePointer<AVPacket>, AVRational)] = []
    /// Live streams are joined mid-GOP: nothing is written before the first video keyframe.
    private var startPTS: Double?
    private var announcedReady = false
    private var lastReadyCheck = Date.distantPast

    init(source: BridgeSource, directory: URL, cancelled: CancellationFlag,
         onEvent: @escaping @Sendable (HLSBridge.Event) -> Void) throws {
        self.source = source
        self.directory = directory
        self.cancelled = cancelled
        self.onEvent = onEvent
    }

    private func isCancelled() -> Bool { cancelled.isSet }

    deinit {
        for (packet, _) in pending {
            var packet: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&packet)
        }
        videoTranscoder = nil
        audioTranscoder = nil
        av_bsf_free(&audioFilter)
        avformat_close_input(&input)
        if let output {
            if output.pointee.pb != nil, output.pointee.oformat.pointee.flags & AVFMT_NOFILE == 0 {
                avio_closep(&output.pointee.pb)
            }
            avformat_free_context(output)
        }
    }

    func run() throws {
        try openInput()
        try openOutput()
        let packet = av_packet_alloc()
        defer {
            var packet = packet
            av_packet_free(&packet)
        }

        while !isCancelled() {
            let read = av_read_frame(input, packet)
            if read == AV.eof {
                // A live source ending isn't the end of the channel: IPTV servers and proxies drop connections,
                // and FFmpeg has already tried to reconnect. Marking the playlist finished would make the TV
                // play out what it has and stop, so report it instead.
                if source.isLive {
                    log.error("Live source stopped after reconnecting")
                    throw BridgeError.sourceStopped
                }
                break
            }
            if read == AV.exit, isCancelled() { return }
            try check(read, "read stream")
            try route(packet!)
            av_packet_unref(packet)
            checkReady()
        }
        if isCancelled() { return }

        try audioTranscoder?.send(nil) { try write($0, from: audioTranscoder!.encoder.pointee.time_base, to: audioOut) }
        if let videoTranscoder {
            try videoTranscoder.send(nil, prepare: { _ in }) { try write($0, from: videoTranscoder.encoder!.pointee.time_base, to: videoOut) }
        }
        if headerWritten { try check(av_write_trailer(output), "finish playlist") }
        checkReady(force: true)
    }

    // MARK: - Input

    private func openInput() throws {
        input = avformat_alloc_context()
        input!.pointee.interrupt_callback = AVIOInterruptCB(
            callback: { opaque in
                guard let opaque else { return 0 }
                return Unmanaged<CancellationFlag>.fromOpaque(opaque).takeUnretainedValue().isSet ? 1 : 0
            },
            // The pipeline holds the flag for as long as FFmpeg can call back.
            opaque: Unmanaged.passUnretained(cancelled).toOpaque()
        )

        var options: [String: String] = [
            // Give up on a dead server instead of hanging; the player then falls back to the FFmpeg player.
            "rw_timeout": "15000000",
            "analyzeduration": "3000000",
            "probesize": "3000000",
        ]
        if ["http", "https"].contains(source.url.scheme?.lowercased()) {
            options["reconnect"] = "1"
            options["reconnect_streamed"] = "1"
            options["reconnect_on_network_error"] = "1"
            options["reconnect_on_http_error"] = "5xx"
            options["reconnect_delay_max"] = "4"
            options["reconnect_max_retries"] = "10"
            options["reconnect_delay_total_max"] = "30"
            // Live servers close connections now and then; reading on through a reconnect keeps the channel going
            // without a gap the player notices.
            if source.isLive { options["reconnect_at_eof"] = "1" }
            if let userAgent = source.headers["User-Agent"] { options["user_agent"] = userAgent }
            let others = source.headers.filter { $0.key != "User-Agent" }
            if !others.isEmpty { options["headers"] = others.map { "\($0.key): \($0.value)\r\n" }.joined() }
        }
        var dictionary = makeDictionary(options)
        defer { av_dict_free(&dictionary) }
        let location = source.url.isFileURL ? source.url.path : source.url.absoluteString
        try check(avformat_open_input(&input, location, nil, &dictionary), "open stream")
        try check(avformat_find_stream_info(input, nil), "read stream info")

        videoIndex = av_find_best_stream(input, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        audioIndex = av_find_best_stream(input, AVMEDIA_TYPE_AUDIO, -1, videoIndex >= 0 ? videoIndex : -1, nil, 0)
        // Still images (cover art) and missing streams count as no video.
        if videoIndex >= 0, stream(videoIndex).pointee.disposition & AV_DISPOSITION_ATTACHED_PIC != 0 { videoIndex = -1 }
        guard videoIndex >= 0 || audioIndex >= 0 else { throw BridgeError.noPlayableStreams }

        let video = videoIndex >= 0 ? stream(videoIndex).pointee.codecpar.pointee : nil
        let audio = audioIndex >= 0 ? stream(audioIndex).pointee.codecpar.pointee : nil
        let interlaced = video.map { $0.field_order != AV_FIELD_PROGRESSIVE && $0.field_order != AV_FIELD_UNKNOWN } ?? false
        plan = BridgePlan(videoCodec: video.map { codecName($0.codec_id) }, interlaced: interlaced,
                          audioCodec: audio.map { codecName($0.codec_id) })
    }

    private func stream(_ index: Int32) -> UnsafeMutablePointer<AVStream> {
        input!.pointee.streams[Int(index)]!
    }

    // MARK: - Output

    private func openOutput() throws {
        let playlist = directory.appending(component: HLSBridge.playlistName).path
        try check(avformat_alloc_output_context2(&output, nil, "hls", playlist), "create playlist")
        let globalHeader = output!.pointee.oformat.pointee.flags & AVFMT_GLOBALHEADER != 0
            || plan.segmentFormat == .fmp4

        if videoIndex >= 0 {
            videoOut = avformat_new_stream(output, nil)
            switch plan.video {
            case .copy:
                try check(avcodec_parameters_copy(videoOut!.pointee.codecpar, stream(videoIndex).pointee.codecpar), "copy video")
                // Apple only plays HEVC tagged as hvc1.
                videoOut!.pointee.codecpar.pointee.codec_tag = plan.segmentFormat == .fmp4 && videoOut!.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_HEVC
                    ? Self.tag("hvc1") : 0
                videoOut!.pointee.time_base = stream(videoIndex).pointee.time_base
            case .transcode(let deinterlace):
                videoTranscoder = try VideoTranscoder(input: stream(videoIndex), deinterlace: deinterlace, globalHeader: globalHeader)
            case nil:
                break
            }
        }
        if audioIndex >= 0 {
            audioOut = avformat_new_stream(output, nil)
            switch plan.audio {
            case .copy:
                let parameters = stream(audioIndex).pointee.codecpar!
                if plan.segmentFormat == .fmp4, parameters.pointee.codec_id == AV_CODEC_ID_AAC {
                    try check(av_bsf_alloc(av_bsf_get_by_name("aac_adtstoasc"), &audioFilter), "AAC filter")
                    try check(avcodec_parameters_copy(audioFilter!.pointee.par_in, parameters), "AAC filter parameters")
                    audioFilter!.pointee.time_base_in = stream(audioIndex).pointee.time_base
                    try check(av_bsf_init(audioFilter), "start AAC filter")
                    try check(avcodec_parameters_copy(audioOut!.pointee.codecpar, audioFilter!.pointee.par_out), "copy audio")
                } else {
                    try check(avcodec_parameters_copy(audioOut!.pointee.codecpar, parameters), "copy audio")
                }
                audioOut!.pointee.codecpar.pointee.codec_tag = 0
                audioOut!.pointee.time_base = stream(audioIndex).pointee.time_base
            case .transcode:
                let transcoder = try AudioTranscoder(input: stream(audioIndex), globalHeader: globalHeader)
                audioTranscoder = transcoder
                try check(avcodec_parameters_from_context(audioOut!.pointee.codecpar, transcoder.encoder), "AAC parameters")
                audioOut!.pointee.time_base = transcoder.encoder.pointee.time_base
            case nil:
                break
            }
        }
        if videoTranscoder == nil { try writeHeader() }
    }

    private func writeHeader() throws {
        let segmentExtension = plan.segmentFormat == .fmp4 ? "m4s" : "ts"
        var options: [String: String] = [
            "hls_time": "2",
            "hls_segment_type": plan.segmentFormat.rawValue,
            "hls_segment_filename": directory.appending(component: "segment%05d.\(segmentExtension)").path,
            // Clients never see a half-written playlist.
            "hls_flags": source.isLive ? "delete_segments+independent_segments+temp_file" : "independent_segments+temp_file",
            "hls_list_size": source.isLive ? "10" : "0",
        ]
        // Keep deleted segments around a while longer: an Apple TV buffering 4K can lag behind the playlist.
        if source.isLive { options["hls_delete_threshold"] = "6" }
        if plan.segmentFormat == .fmp4 { options["hls_fmp4_init_filename"] = "init.mp4" }
        if !source.isLive { options["hls_playlist_type"] = "event" }
        var dictionary = makeDictionary(options)
        defer { av_dict_free(&dictionary) }
        try check(avformat_write_header(output, &dictionary), "start playlist")
        headerWritten = true

        let queued = pending
        pending = []
        for (packet, timeBase) in queued {
            var packet: UnsafeMutablePointer<AVPacket>? = packet
            defer { av_packet_free(&packet) }
            let target = packet!.pointee.stream_index == videoOut?.pointee.index ? videoOut : audioOut
            try write(packet!, from: timeBase, to: target)
        }
    }

    // MARK: - Packets

    private func route(_ packet: UnsafeMutablePointer<AVPacket>) throws {
        let index = packet.pointee.stream_index
        guard index == videoIndex || index == audioIndex else { return }
        let timeBase = stream(index).pointee.time_base

        // Start on a video keyframe, and drop audio from before it.
        let time = packet.pointee.pts != AV.noPTS ? Double(packet.pointee.pts) * timeBase.seconds : nil
        if startPTS == nil {
            if videoIndex >= 0 {
                guard index == videoIndex, packet.pointee.flags & AV_PKT_FLAG_KEY != 0, let time else { return }
                startPTS = time
            } else {
                startPTS = time ?? 0
            }
        } else if index == audioIndex, let time, let startPTS, time < startPTS - 0.1 {
            return
        }

        if index == videoIndex {
            if let videoTranscoder {
                try videoTranscoder.send(packet, prepare: { encoder in
                    try check(avcodec_parameters_from_context(videoOut!.pointee.codecpar, encoder), "H.264 parameters")
                    videoOut!.pointee.time_base = encoder.pointee.time_base
                    try writeHeader()
                }) { try write($0, from: videoTranscoder.encoder!.pointee.time_base, to: videoOut) }
            } else {
                try write(packet, from: timeBase, to: videoOut)
            }
        } else if let audioTranscoder {
            try audioTranscoder.send(packet) { try write($0, from: audioTranscoder.encoder.pointee.time_base, to: audioOut) }
        } else if let audioFilter {
            guard av_bsf_send_packet(audioFilter, packet) >= 0 else { return }
            while av_bsf_receive_packet(audioFilter, packet) >= 0 {
                try write(packet, from: timeBase, to: audioOut)
                av_packet_unref(packet)
            }
        } else {
            try write(packet, from: timeBase, to: audioOut)
        }
    }

    /// Writes a packet whose timestamps are in `timeBase` to `stream`, or holds it until the header is written.
    private func write(_ packet: UnsafeMutablePointer<AVPacket>, from timeBase: AVRational,
                       to stream: UnsafeMutablePointer<AVStream>?) throws {
        guard let stream else { return }
        // Packets without any timestamp can't be placed in a segment.
        if packet.pointee.pts == AV.noPTS, packet.pointee.dts == AV.noPTS { return }
        packet.pointee.stream_index = stream.pointee.index
        guard headerWritten else {
            pending.append((av_packet_clone(packet), timeBase))
            return
        }
        av_packet_rescale_ts(packet, timeBase, stream.pointee.time_base)
        packet.pointee.pos = -1
        let written = av_interleaved_write_frame(output, packet)
        // A single out-of-order timestamp (common after a source glitch) shouldn't end the stream.
        if written < 0, written != AV.invalidData { try check(written, "write segment") }
    }

    /// Announces readiness once the playlist lists two segments, which is what AVPlayer needs to start live.
    private func checkReady(force: Bool = false) {
        guard !announcedReady, force || Date().timeIntervalSince(lastReadyCheck) > 0.25 else { return }
        lastReadyCheck = Date()
        let playlist = directory.appending(component: HLSBridge.playlistName)
        guard let text = try? String(contentsOf: playlist, encoding: .utf8) else { return }
        let segments = text.components(separatedBy: "#EXTINF").count - 1
        if segments >= 2 || (force && segments >= 1) {
            announcedReady = true
            onEvent(.ready(plan))
        }
    }

    private static func tag(_ code: String) -> UInt32 {
        let bytes = Array(code.utf8)
        return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
    }
}
