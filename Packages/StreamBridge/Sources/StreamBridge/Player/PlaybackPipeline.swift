// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AVFoundation
import CoreMedia
import FFmpeg
import Foundation
import OSLog
import Synchronization

private let log = Logger(subsystem: "app.rptv.RpTv", category: "StreamPlayer")

/// The threads behind a ``StreamPlayer``: one reads and demuxes, one decodes video into the display layer's
/// renderer, one decodes audio into the audio renderer. The renderers play what they're given against the
/// synchronizer's clock, which ``StreamPlayer`` starts and stops.
///
/// Every timestamp is moved onto one timeline before it's queued: finite media start at zero, live streams start
/// near zero and stay continuous across discontinuities (``LiveTimeline``).
final class PlaybackPipeline: @unchecked Sendable {
    enum Message: Sendable {
        case opened(Info)
        case failed(String)
        /// A subtitle track no container lists: the closed captions inside the video, or a teletext subtitle
        /// page that showed up.
        case foundTrack(PlayerTrack)
    }

    /// The subtitle track of the closed captions inside the video.
    static let captionTrackID: Int32 = -608

    /// The subtitle track of a teletext page: one stream carries several pages, each a track of its own.
    static func teletextTrackID(stream: Int32, page: TeletextPage) -> Int32 {
        0x4000_0000 | stream << 12 | Int32(page.magazine << 8 | page.number)
    }

    struct Info: Sendable {
        var duration: TimeInterval?
        var isSeekable: Bool
        var hasVideo: Bool
        var tracks: [PlayerTrack]
    }

    /// What the threads share. Only the reading thread changes `serial`, `origin` and the subtitles.
    struct State {
        /// Bumped by each seek; packets and decoded output carry the serial they belong to.
        var serial = 0
        /// Where playback starts for the current serial: the seek target, or a live stream's first keyframe.
        var origin: Double?
        var seekRequest: (target: Double, id: Int)?
        var appliedSeeks = 0
        var reachedEnd = false
        /// Why reading stopped before the end of finite media.
        var readError: String?
        var selectedAudio: Int32 = -1
        var audioSelections = 0
        var selectedSubtitle: Int32?
        var videoEnabled = true
        var videoUnavailable = false
        var unavailableAudio: Set<Int32> = []
        var firstVideoSerial = -1
        var videoEndedSerial = -1
        var audioEndedSerial = -1
        /// Where the last picture and audio sent to the renderers end.
        var videoEnd = 0.0
        var audioEnd = 0.0
        var videoSize = CGSize.zero
        var subtitles: [Int32: SubtitleTrackCues] = [:]
        var hasCaptions = false
    }

    /// The most read ahead, so memory stays bounded and a paused live stream stops downloading.
    private static let maxBuffer = 30.0
    private static let maxBytes = 64 << 20

    let source: PlayerSource
    let state = Mutex(State())
    private let videoRenderer: AVSampleBufferVideoRenderer
    private let audioRenderer: AVSampleBufferAudioRenderer
    private let timebase: CMTimebase
    private let cancelled = CancellationFlag()
    private let send: @Sendable (Message) -> Void

    // Set up by the reading thread before the decoding threads start, then only read.
    private var input: UnsafeMutablePointer<AVFormatContext>?
    private var video: StreamParameters?
    private var audios: [Int32: StreamParameters] = [:]
    private var queues: [Int32: PacketQueue] = [:]

    // The reading thread's own.
    private var subtitleDecoders: [Int32: SubtitleDecoder] = [:]
    private var teletextDecoders: [Int32: TeletextDecoder] = [:]
    private var timeline = LiveTimeline()
    private var formatStart = 0.0
    private var waitingForKeyframe = true
    private var skippedBeforeKeyframe = 0
    private var reachedEnd = false

    init(source: PlayerSource, videoRenderer: AVSampleBufferVideoRenderer, audioRenderer: AVSampleBufferAudioRenderer,
         timebase: CMTimebase, send: @escaping @Sendable (Message) -> Void) {
        self.source = source
        self.videoRenderer = videoRenderer
        self.audioRenderer = audioRenderer
        self.timebase = timebase
        self.send = send
    }

    deinit {
        avformat_close_input(&input)
    }

    func start() {
        spawn("StreamPlayer.read") { $0.runReading() }
    }

    /// Stops every thread as soon as it returns from FFmpeg, including from a blocked network read.
    func cancel() {
        cancelled.set()
    }

    private func spawn(_ name: String, _ body: @escaping @Sendable (PlaybackPipeline) -> Void) {
        let thread = Thread { [self] in body(self) }
        thread.name = name
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private var clock: Double { CMTimebaseGetTime(timebase).seconds }
    private var clockIsRunning: Bool { CMTimebaseGetRate(timebase) > 0 }

    // MARK: - Control

    func requestSeek(to target: Double, id: Int) {
        state.withLock { $0.seekRequest = (target, id) }
    }

    func selectAudio(_ index: Int32) {
        state.withLock {
            guard $0.selectedAudio != index else { return }
            $0.selectedAudio = index
            $0.audioSelections += 1
        }
    }

    /// How far every stream that matters has been read: the earliest of the latest timestamps of the video and
    /// the selected audio. `.infinity` once the end is reached. `lenient` ignores a stream that hasn't sent
    /// anything (an audio stream that's declared but silent shouldn't hold up the picture).
    func bufferedUntil(lenient: Bool) -> Double? {
        let (selected, videoEnabled, videoUnavailable, unavailable) = state.withLock {
            ($0.selectedAudio, $0.videoEnabled, $0.videoUnavailable, $0.unavailableAudio)
        }
        var active: [PacketQueue] = []
        if let video, videoEnabled, !videoUnavailable, let queue = queues[video.index] { active.append(queue) }
        if !unavailable.contains(selected), let queue = queues[selected] { active.append(queue) }
        var times: [Double] = []
        for queue in active {
            if queue.isFinished {
                times.append(.infinity)
            } else if let time = queue.latestTime {
                times.append(time)
            } else if !lenient {
                return nil
            }
        }
        return times.min()
    }

    /// The selected subtitle track's cue at `time`.
    func cue(at time: Double) -> SubtitleCue? {
        state.withLock { state in state.selectedSubtitle.flatMap { state.subtitles[$0]?.cue(at: time) } }
    }

    // MARK: - Reading

    private func runReading() {
        let info: Info
        do {
            info = try open()
        } catch {
            if !cancelled.isSet {
                log.error("Open failed: \(error.localizedDescription, privacy: .public)")
                send(.failed(error.localizedDescription))
            }
            return
        }
        guard !cancelled.isSet else { return }
        // Before the decoders start, so nothing they report arrives ahead of it.
        send(.opened(info))
        if let video { spawn("StreamPlayer.video") { $0.runVideo(video) } }
        if !audios.isEmpty { spawn("StreamPlayer.audio") { $0.runAudio() } }

        var packet: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer { av_packet_free(&packet) }
        while !cancelled.isSet {
            if let request = state.withLock({ state in defer { state.seekRequest = nil }; return state.seekRequest }) {
                seek(to: request.target, id: request.id)
                continue
            }
            if reachedEnd || isBufferFull {
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }
            let result = av_read_frame(input, packet)
            if result == AV.again {
                Thread.sleep(forTimeInterval: 0.005)
                continue
            }
            if result < 0 {
                if cancelled.isSet { return }
                // What's read still plays; ``StreamPlayer`` reports the problem once it has played out. A live
                // stream has no end, so it has stopped either way (FFmpeg has already tried to reconnect).
                let error = result == AV.eof ? nil : FFmpegError(result, "read stream")
                if let error { log.error("Reading stopped: \(error.localizedDescription, privacy: .public)") }
                for queue in queues.values { queue.finish() }
                state.withLock {
                    $0.reachedEnd = true
                    $0.readError = error?.localizedDescription
                }
                reachedEnd = true
                continue
            }
            route(packet!)
            av_packet_unref(packet)
        }
    }

    private func open() throws -> Info {
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
            // Give up on a dead server instead of hanging.
            "rw_timeout": "15000000",
            // MPEG-TS has no header, so FFmpeg reads all of this before anything plays: on a channel sent in real
            // time, that much waiting. Live channels get half a second, which finds every stream; the decoders
            // learn the rest (such as the picture size, sent with the next keyframe).
            "analyzeduration": source.isLive ? "500000" : "3000000",
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
            // Live servers close connections now and then; reading on through a reconnect keeps the channel going.
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
        let input = input!

        if !source.isLive, input.pointee.start_time != AV.noPTS {
            formatStart = Double(input.pointee.start_time) / Double(AV_TIME_BASE)
        }

        var videoIndex = av_find_best_stream(input, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        // Cover art isn't video.
        if videoIndex >= 0, input.pointee.streams[Int(videoIndex)]!.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC != 0 {
            videoIndex = -1
        }
        if videoIndex >= 0 {
            let stream = input.pointee.streams[Int(videoIndex)]!
            video = StreamParameters(stream: stream, frameRate: av_guess_frame_rate(input, stream, nil))
            queues[videoIndex] = PacketQueue()
        }
        var tracks: [PlayerTrack] = []
        for index in 0..<Int32(input.pointee.nb_streams) {
            let stream = input.pointee.streams[Int(index)]!
            let parameters = stream.pointee.codecpar!
            let codec = codecName(parameters.pointee.codec_id)
            switch parameters.pointee.codec_type {
            case AVMEDIA_TYPE_AUDIO:
                guard avcodec_find_decoder(parameters.pointee.codec_id) != nil, parameters.pointee.sample_rate > 0 else { continue }
                audios[index] = StreamParameters(stream: stream, frameRate: AVRational())
                queues[index] = PacketQueue()
                tracks.append(PlayerTrack(id: index, kind: .audio, title: Self.metadata(stream, "title"),
                                          language: Self.metadata(stream, "language"), codec: codec,
                                          channels: Int(parameters.pointee.ch_layout.nb_channels), isSelected: false))
            case AVMEDIA_TYPE_SUBTITLE where parameters.pointee.codec_id == AV_CODEC_ID_DVB_TELETEXT:
                let pages = Self.teletextPages(stream)
                teletextDecoders[index] = TeletextDecoder(listedPages: pages.reduce(into: [:]) { $0[$1.page] = $1.language },
                                                          idBase: Int(index) << 32)
                for entry in pages where entry.isSubtitle {
                    tracks.append(PlayerTrack(id: Self.teletextTrackID(stream: index, page: entry.page), kind: .subtitle,
                                              title: nil, language: entry.language, codec: codec, channels: 0,
                                              isSelected: false))
                }
            case AVMEDIA_TYPE_SUBTITLE:
                guard SubtitleDecoder.canDecode(parameters),
                      let decoder = try? SubtitleDecoder(stream: stream, idBase: Int(index) << 32) else { continue }
                subtitleDecoders[index] = decoder
                tracks.append(PlayerTrack(id: index, kind: .subtitle, title: Self.metadata(stream, "title"),
                                          language: Self.metadata(stream, "language"), codec: codec, channels: 0,
                                          isSelected: false))
            default:
                break
            }
        }
        guard video != nil || !audios.isEmpty else { throw PlayerError.noPlayableStreams }

        let audioTracks = tracks.filter { $0.kind == .audio }
        let best = av_find_best_stream(input, AVMEDIA_TYPE_AUDIO, -1, videoIndex, nil, 0)
        let audio = source.prefersAudioLanguage.flatMap { prefers in audioTracks.first { prefers($0.language) }?.id }
            ?? (audios[best] != nil ? best : audioTracks.first?.id ?? -1)
        let subtitle = source.prefersSubtitleLanguage.flatMap { prefers in
            tracks.first { $0.kind == .subtitle && prefers($0.language) }?.id
        }
        for index in tracks.indices {
            tracks[index].isSelected = tracks[index].id == audio || tracks[index].id == subtitle
        }

        let duration = !source.isLive && input.pointee.duration > 0 ? Double(input.pointee.duration) / Double(AV_TIME_BASE) : nil
        let isSeekable = duration != nil && (input.pointee.pb == nil || input.pointee.pb.pointee.seekable != 0)
        waitingForKeyframe = video != nil
        state.withLock {
            $0.selectedAudio = audio
            $0.selectedSubtitle = subtitle
            // Live streams start at their first keyframe; finite ones at the start, or where they were left.
            $0.origin = source.isLive ? nil : 0
        }
        if isSeekable, let start = source.startPosition, start > 0, let duration, start < duration {
            seek(to: start, id: 0)
        }
        return Info(duration: duration, isSeekable: isSeekable, hasVideo: video != nil, tracks: tracks)
    }

    /// The pages a teletext stream's descriptor lists. FFmpeg keeps the descriptor's languages in the metadata
    /// ("eng,fra") and two bytes per page in the extradata: type and magazine, then the page number.
    private static func teletextPages(_ stream: UnsafeMutablePointer<AVStream>)
        -> [(page: TeletextPage, language: String?, isSubtitle: Bool)] {
        let parameters = stream.pointee.codecpar.pointee
        guard let extradata = parameters.extradata, parameters.extradata_size >= 2 else { return [] }
        let languages = metadata(stream, "language")?.split(separator: ",").map(String.init) ?? []
        return (0..<Int(parameters.extradata_size) / 2).map { index in
            let first = extradata[index * 2], number = Int(extradata[index * 2 + 1])
            let magazine = Int(first & 7) == 0 ? 8 : Int(first & 7)
            // Types 2 and 5: subtitles, and subtitles for the hard of hearing.
            let type = first >> 3
            let language = index < languages.count ? languages[index] : nil
            return (TeletextPage(magazine: magazine, number: number), language, type == 2 || type == 5)
        }
    }

    private static func metadata(_ stream: UnsafeMutablePointer<AVStream>, _ key: String) -> String? {
        guard let entry = av_dict_get(stream.pointee.metadata, key, nil, 0), let value = entry.pointee.value else { return nil }
        let text = String(cString: value).trimmingCharacters(in: .whitespaces)
        return text.isEmpty || text == "und" ? nil : text
    }

    private var isBufferFull: Bool {
        let selected = state.withLock { $0.selectedAudio }
        var buffered = 0.0
        if let video, let queue = queues[video.index] { buffered = max(buffered, queue.duration) }
        if let queue = queues[selected] { buffered = max(buffered, queue.duration) }
        let bytes = queues.values.reduce(0) { $0 + $1.bytes }
        return buffered >= max(Self.maxBuffer, (source.buffer ?? 0) * 2) || bytes >= Self.maxBytes
    }

    private func seek(to target: Double, id: Int) {
        let timestamp = Int64((target + formatStart) * Double(AV_TIME_BASE))
        if avformat_seek_file(input, -1, Int64.min, timestamp, timestamp, 0) < 0 {
            av_seek_frame(input, -1, timestamp, AVSEEK_FLAG_BACKWARD)
        }
        // Queues first, so nobody sees the new serial with the old packets.
        let serial = state.withLock { $0.serial } + 1
        for queue in queues.values { queue.flush(serial: serial) }
        for decoder in subtitleDecoders.values { decoder.flush() }
        for decoder in teletextDecoders.values { decoder.reset() }
        state.withLock {
            $0.serial = serial
            $0.origin = target
            $0.appliedSeeks = id
            $0.reachedEnd = false
            $0.readError = nil
            $0.videoEnd = target
            $0.audioEnd = target
            $0.subtitles = [:]
        }
        waitingForKeyframe = video != nil
        skippedBeforeKeyframe = 0
        reachedEnd = false
    }

    private func route(_ packet: UnsafeMutablePointer<AVPacket>) {
        let index = packet.pointee.stream_index
        let isVideo = index == video?.index
        let isAudio = audios[index] != nil
        let subtitleDecoder = subtitleDecoders[index]
        let teletextDecoder = teletextDecoders[index]
        guard isVideo || isAudio || subtitleDecoder != nil || teletextDecoder != nil else { return }
        let timeBase = input!.pointee.streams[Int(index)]!.pointee.time_base

        // Onto the player's timeline.
        let raw = packet.pointee.dts != AV.noPTS ? packet.pointee.dts : packet.pointee.pts
        if raw != AV.noPTS, timeBase.num > 0 {
            let seconds = Double(raw) * timeBase.seconds
            let offset = !source.isLive ? -formatStart
                : subtitleDecoder != nil || teletextDecoder != nil ? timeline.sparseOffset(forRaw: seconds)
                : timeline.offset(forRaw: seconds, stream: index)
            let ticks = Int64((offset / timeBase.seconds).rounded())
            if packet.pointee.pts != AV.noPTS { packet.pointee.pts += ticks }
            if packet.pointee.dts != AV.noPTS { packet.pointee.dts += ticks }
        }
        let timestamp = packet.pointee.pts != AV.noPTS ? packet.pointee.pts : packet.pointee.dts
        let time = timestamp != AV.noPTS ? Double(timestamp) * timeBase.seconds : nil

        if isVideo {
            if waitingForKeyframe {
                // Some streams never flag keyframes; after a few seconds, start anyway.
                skippedBeforeKeyframe += 1
                guard packet.pointee.flags & AV_PKT_FLAG_KEY != 0 || skippedBeforeKeyframe > 150 else { return }
                waitingForKeyframe = false
                if source.isLive, let time { state.withLock { if $0.origin == nil { $0.origin = time } } }
            }
            queues[index]!.push(packet, time: time)
        } else if isAudio {
            let (origin, selected) = state.withLock { ($0.origin, $0.selectedAudio) }
            if origin == nil {
                // Live: wait for the picture, or start with the sound when there's no picture.
                guard video == nil, index == selected, let time else { return }
                state.withLock { $0.origin = time }
            }
            // Tracks nobody listens to keep just enough to switch to them.
            if index != selected { queues[index]!.dropOlder(than: clock - 1) }
            queues[index]!.push(packet, time: time)
        } else if let subtitleDecoder {
            let size = state.withLock { $0.videoSize }
            guard let cue = subtitleDecoder.decode(packet, videoSize: size == .zero ? CGSize(width: 720, height: 576) : size)
            else { return }
            let now = clock
            state.withLock {
                $0.subtitles[index, default: SubtitleTrackCues()].add(cue)
                $0.subtitles[index]!.dropEnded(before: now - 1)
            }
        } else if let teletextDecoder, let time, let data = packet.pointee.data {
            let found = teletextDecoder.foundPages.count
            let updates = teletextDecoder.decode(Array(UnsafeBufferPointer(start: data, count: Int(packet.pointee.size))),
                                                 time: time)
            let now = clock
            state.withLock { state in
                for update in updates {
                    let track = Self.teletextTrackID(stream: index, page: update.page)
                    state.subtitles[track, default: SubtitleTrackCues()].add(update.cue)
                    state.subtitles[track]!.dropEnded(before: now - 1)
                }
            }
            let language = Self.metadata(input!.pointee.streams[Int(index)]!, "language")?.split(separator: ",").first.map(String.init)
            for page in teletextDecoder.foundPages[found...] {
                send(.foundTrack(PlayerTrack(id: Self.teletextTrackID(stream: index, page: page), kind: .subtitle,
                                             title: nil, language: language, codec: "dvb_teletext", channels: 0,
                                             isSelected: false)))
            }
        }
    }

    // MARK: - Video

    private func runVideo(_ stream: StreamParameters) {
        let queue = queues[stream.index]!
        let decoder: VideoDecoder
        do {
            decoder = try VideoDecoder(stream: stream)
        } catch {
            log.error("No video: \(error.localizedDescription, privacy: .public)")
            state.withLock { $0.videoUnavailable = true }
            discardAll(from: queue)
            return
        }
        let fieldOrder = stream.parameters.pointee.field_order
        let converter = VideoConverter(timeBase: stream.timeBase, frameRate: stream.frameRate,
                                       interlaced: fieldOrder != AV_FIELD_PROGRESSIVE && fieldOrder != AV_FIELD_UNKNOWN)
        var serial = queue.serial
        var format: CMVideoFormatDescription?
        var drained = false
        var suspended = false
        var needsKeyframe = false
        var captions: SubtitleDecoder?

        func reset(to newSerial: Int) {
            serial = newSerial
            decoder.flush()
            converter.reset()
            captions?.flush()
            videoRenderer.flush()
            drained = false
        }

        /// US broadcasts carry CEA-608 captions in the video frames. They're read from every frame, shown or not,
        /// since each frame holds only two characters.
        func readCaptions(of frame: UnsafeMutablePointer<AVFrame>) {
            guard let data = av_frame_get_side_data(frame, AV_FRAME_DATA_A53_CC), data.pointee.size > 0 else { return }
            let timestamp = frame.pointee.best_effort_timestamp != AV.noPTS ? frame.pointee.best_effort_timestamp : frame.pointee.pts
            guard timestamp != AV.noPTS else { return }
            if captions == nil { captions = try? SubtitleDecoder(captionsIn: stream.timeBase, idBase: 1 << 40) }
            guard let cue = captions?.decodeCaptions(UnsafeRawBufferPointer(start: data.pointee.data, count: data.pointee.size),
                                                     timestamp: timestamp) else { return }
            let now = clock
            let found = state.withLock { state -> Bool in
                guard state.serial == serial else { return false }
                state.subtitles[Self.captionTrackID, default: SubtitleTrackCues()].add(cue)
                state.subtitles[Self.captionTrackID]!.dropEnded(before: now - 1)
                guard !state.hasCaptions, !cue.isEmpty else { return false }
                state.hasCaptions = true
                return true
            }
            if found {
                send(.foundTrack(PlayerTrack(id: Self.captionTrackID, kind: .subtitle, title: nil, language: nil,
                                             codec: "eia_608", channels: 0, isSelected: false)))
            }
        }

        func show(_ frame: UnsafeMutablePointer<AVFrame>) {
            readCaptions(of: frame)
            let origin = state.withLock { $0.origin }
            if let time = converter.time(of: frame) {
                // Frames decoded only to reach a seek target, and frames already late, aren't converted.
                if let origin, time < origin - 0.001 { return }
                if clockIsRunning, time + 0.3 < clock { return }
            }
            do {
                try converter.convert(frame) { picture in
                    if clockIsRunning, picture.time + picture.duration < clock { return }
                    guard waitUntilReady(serial: serial, queue: queue, { videoRenderer.isReadyForMoreMediaData }),
                          let sample = picture.sampleBuffer(format: &format) else { return }
                    videoRenderer.enqueue(sample)
                    let size = CGSize(width: CVPixelBufferGetWidth(picture.pixelBuffer),
                                      height: CVPixelBufferGetHeight(picture.pixelBuffer))
                    state.withLock {
                        $0.firstVideoSerial = serial
                        $0.videoEnd = picture.time + picture.duration
                        $0.videoSize = size
                    }
                }
            } catch {
                log.error("Video frame dropped: \(error.localizedDescription, privacy: .public)")
            }
        }

        while !cancelled.isSet {
            switch queue.pop(timeout: 0.05) {
            case .timedOut:
                continue
            case .end(let itemSerial):
                if itemSerial != serial { reset(to: itemSerial) }
                if drained {
                    Thread.sleep(forTimeInterval: 0.02)
                    continue
                }
                drained = true
                decoder.decode(nil, emit: show)
                state.withLock { $0.videoEndedSerial = serial }
            case .packet(let packet, let itemSerial):
                defer {
                    var packet: UnsafeMutablePointer<AVPacket>? = packet
                    av_packet_free(&packet)
                }
                if itemSerial != serial { reset(to: itemSerial) }
                // In the background without Picture in Picture, nobody sees the video: skip decoding it.
                guard state.withLock({ $0.videoEnabled }) else {
                    suspended = true
                    continue
                }
                if suspended {
                    suspended = false
                    decoder.flush()
                    converter.reset()
                    needsKeyframe = true
                }
                if needsKeyframe {
                    guard packet.pointee.flags & AV_PKT_FLAG_KEY != 0 else { continue }
                    needsKeyframe = false
                }
                decoder.decode(packet, emit: show)
            }
        }
    }

    // MARK: - Audio

    private func runAudio() {
        var (selected, selections) = state.withLock { ($0.selectedAudio, $0.audioSelections) }
        var decoder = makeAudioDecoder(selected)
        var queue = queues[selected] ?? PacketQueue()
        var serial = queue.serial
        /// After switching tracks mid-play, the new one starts from the playhead.
        var switchTime: Double?
        var drained = false

        func send(_ sample: CMSampleBuffer) {
            let end = (CMSampleBufferGetPresentationTimeStamp(sample) + CMSampleBufferGetDuration(sample)).seconds
            if clockIsRunning, end < clock { return }
            guard waitUntilReady(serial: serial, queue: queue, {
                audioRenderer.isReadyForMoreMediaData || state.withLock { $0.audioSelections } != selections
            }), state.withLock({ $0.audioSelections }) == selections else { return }
            audioRenderer.enqueue(sample)
            state.withLock { $0.audioEnd = end }
        }

        while !cancelled.isSet {
            let current = state.withLock { ($0.selectedAudio, $0.audioSelections) }
            if current.1 != selections {
                (selected, selections) = current
                audioRenderer.flush()
                decoder = makeAudioDecoder(selected)
                queue = queues[selected] ?? PacketQueue()
                serial = queue.serial
                switchTime = clock + 0.05
                drained = false
            }
            switch queue.pop(timeout: 0.05) {
            case .timedOut:
                continue
            case .end(let itemSerial):
                if itemSerial != serial {
                    serial = itemSerial
                    decoder?.flush()
                    audioRenderer.flush()
                    switchTime = nil
                    drained = false
                }
                if drained {
                    Thread.sleep(forTimeInterval: 0.02)
                    continue
                }
                drained = true
                decoder?.decode(nil, trimBefore: nil, emit: send)
                state.withLock { $0.audioEndedSerial = serial }
            case .packet(let packet, let itemSerial):
                defer {
                    var packet: UnsafeMutablePointer<AVPacket>? = packet
                    av_packet_free(&packet)
                }
                if itemSerial != serial {
                    serial = itemSerial
                    decoder?.flush()
                    audioRenderer.flush()
                    switchTime = nil
                    drained = false
                }
                guard let decoder else { continue }
                let origin = state.withLock { $0.origin }
                let trim = [origin, switchTime].compactMap { $0 }.max()
                decoder.decode(packet, trimBefore: trim, emit: send)
            }
        }
    }

    private func makeAudioDecoder(_ index: Int32) -> AudioDecoder? {
        guard let stream = audios[index] else { return nil }
        do {
            return try AudioDecoder(stream: stream)
        } catch {
            log.error("No audio: \(error.localizedDescription, privacy: .public)")
            state.withLock { _ = $0.unavailableAudio.insert(index) }
            return nil
        }
    }

    // MARK: - Helpers

    /// Waits for a renderer to take more, giving up when the pipeline is cancelled or a seek starts a new serial.
    private func waitUntilReady(serial: Int, queue: PacketQueue, _ isReady: () -> Bool) -> Bool {
        while !isReady() {
            if cancelled.isSet || queue.serial != serial { return false }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return !cancelled.isSet && queue.serial == serial
    }

    private func discardAll(from queue: PacketQueue) {
        while !cancelled.isSet {
            switch queue.pop(timeout: 0.1) {
            case .packet(let packet, _):
                var packet: UnsafeMutablePointer<AVPacket>? = packet
                av_packet_free(&packet)
            case .end:
                Thread.sleep(forTimeInterval: 0.05)
            case .timedOut:
                break
            }
        }
    }
}
