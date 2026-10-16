// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics
import FFmpeg
import Foundation

/// One subtitle on screen: text, or the pictures of a bitmap subtitle (DVB, Blu-ray, DVD).
public struct SubtitleCue: Sendable, Identifiable, Equatable {
    public enum Content: Sendable {
        case text(String)
        case images([SubtitleImage])
    }

    public let id: Int
    /// Seconds on the player's timeline.
    public var start: Double
    public var end: Double
    public var content: Content

    public static func == (lhs: SubtitleCue, rhs: SubtitleCue) -> Bool { lhs.id == rhs.id }

    /// A cue with nothing to show, which clears the screen.
    var isEmpty: Bool {
        switch content {
        case .text(let text): text.isEmpty
        case .images(let images): images.isEmpty
        }
    }
}

/// A bitmap subtitle picture and where it goes, as fractions (0…1) of the video picture.
public struct SubtitleImage: @unchecked Sendable {
    public var image: CGImage
    public var frame: CGRect
}

/// Decodes one subtitle stream, or the CEA-608 captions in video frames, into cues. Text loses its styling;
/// bitmaps become images. Teletext goes through ``TeletextDecoder`` instead.
final class SubtitleDecoder {
    private let context: UnsafeMutablePointer<AVCodecContext>
    private let timeBase: AVRational
    private let isBitmap: Bool
    /// How long a text subtitle that doesn't say when it ends stays up, unless the next one replaces it.
    private let openEndedDuration: Double
    private let packet: UnsafeMutablePointer<AVPacket>
    private var nextID = 0

    /// Whether FFmpeg can decode the stream's subtitles.
    static func canDecode(_ parameters: UnsafeMutablePointer<AVCodecParameters>) -> Bool {
        avcodec_find_decoder(parameters.pointee.codec_id) != nil
    }

    init(stream: UnsafeMutablePointer<AVStream>, idBase: Int) throws {
        let parameters = stream.pointee.codecpar!
        guard let codec = avcodec_find_decoder(parameters.pointee.codec_id) else {
            throw PlayerError.unsupportedCodec(codecName(parameters.pointee.codec_id))
        }
        context = avcodec_alloc_context3(codec)
        try check(avcodec_parameters_to_context(context, parameters), "subtitle decoder parameters")
        context.pointee.pkt_timebase = stream.pointee.time_base
        try check(avcodec_open2(context, codec, nil), "open subtitle decoder")
        timeBase = stream.pointee.time_base
        isBitmap = avcodec_descriptor_get(parameters.pointee.codec_id).map {
            $0.pointee.props & AV_CODEC_PROP_BITMAP_SUB != 0
        } ?? false
        nextID = idBase
        openEndedDuration = 5
        packet = av_packet_alloc()
    }

    /// A decoder for the CEA-608 closed captions in video frames (`AV_FRAME_DATA_A53_CC`), whose timestamps
    /// are in `timeBase`.
    init(captionsIn timeBase: AVRational, idBase: Int) throws {
        guard let codec = avcodec_find_decoder(AV_CODEC_ID_EIA_608) else { throw PlayerError.unsupportedCodec("eia_608") }
        context = avcodec_alloc_context3(codec)
        context.pointee.pkt_timebase = timeBase
        // By default a caption arrives only once it's taken down; real time sends each change as it happens.
        var options = makeDictionary(["real_time": "1"])
        defer { av_dict_free(&options) }
        try check(avcodec_open2(context, codec, &options), "open caption decoder")
        self.timeBase = timeBase
        isBitmap = false
        nextID = idBase
        // Each change replaces the last; the cap only matters if a stream stops sending captions mid-sentence.
        openEndedDuration = 10
        packet = av_packet_alloc()
    }

    deinit {
        var context: UnsafeMutablePointer<AVCodecContext>? = context
        avcodec_free_context(&context)
        var packet: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&packet)
    }

    /// Decodes one frame's caption data (`AV_FRAME_DATA_A53_CC`), shown at `timestamp` in the decoder's time base.
    func decodeCaptions(_ data: UnsafeRawBufferPointer, timestamp: Int64) -> SubtitleCue? {
        guard let base = data.baseAddress, !data.isEmpty, av_new_packet(packet, Int32(data.count)) >= 0 else { return nil }
        defer { av_packet_unref(packet) }
        packet.pointee.data.update(from: base.assumingMemoryBound(to: UInt8.self), count: data.count)
        packet.pointee.pts = timestamp
        packet.pointee.dts = timestamp
        // Each update is the screen as of this frame. (The decoder stamps it with the previous change's time.)
        guard var cue = decode(packet, videoSize: .zero) else { return nil }
        cue.start = Double(timestamp) * timeBase.seconds
        cue.end = cue.start + openEndedDuration
        return cue
    }

    func flush() {
        avcodec_flush_buffers(context)
    }

    /// Decodes a packet into its cue, or an empty cue when it clears the screen. `videoSize` places bitmaps
    /// whose stream doesn't give the picture size.
    func decode(_ packet: UnsafeMutablePointer<AVPacket>, videoSize: CGSize) -> SubtitleCue? {
        var subtitle = AVSubtitle()
        var got: Int32 = 0
        guard avcodec_decode_subtitle2(context, &subtitle, &got, packet) >= 0, got != 0 else { return nil }
        defer { avsubtitle_free(&subtitle) }

        let packetTime = packet.pointee.pts != AV.noPTS ? Double(packet.pointee.pts) * timeBase.seconds : nil
        let base = subtitle.pts != AV.noPTS ? Double(subtitle.pts) / Double(AV_TIME_BASE) : packetTime ?? 0
        let start = base + Double(subtitle.start_display_time) / 1000
        var end = Double.infinity
        if subtitle.end_display_time > subtitle.start_display_time, subtitle.end_display_time != UInt32.max {
            end = base + Double(subtitle.end_display_time) / 1000
        } else if packet.pointee.duration > 0 {
            end = start + Double(packet.pointee.duration) * timeBase.seconds
        } else if !isBitmap {
            end = start + openEndedDuration
        }

        var lines: [String] = []
        var images: [SubtitleImage] = []
        let canvas = CGSize(width: context.pointee.width > 0 ? CGFloat(context.pointee.width) : videoSize.width,
                            height: context.pointee.height > 0 ? CGFloat(context.pointee.height) : videoSize.height)
        for index in 0..<Int(subtitle.num_rects) {
            guard let rect = subtitle.rects[index] else { continue }
            switch rect.pointee.type {
            case SUBTITLE_BITMAP:
                if let image = Self.image(of: rect, canvas: canvas) { images.append(image) }
            case SUBTITLE_ASS:
                if let ass = rect.pointee.ass { lines.append(Self.plainText(fromASS: String(cString: ass))) }
            case SUBTITLE_TEXT:
                if let text = rect.pointee.text { lines.append(String(cString: text)) }
            default:
                break
            }
        }
        nextID += 1
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let content: SubtitleCue.Content = images.isEmpty ? .text(text) : .images(images)
        return SubtitleCue(id: nextID, start: start, end: end, content: content)
    }

    /// The text of an ASS dialogue line, without its fields and override tags.
    static func plainText(fromASS line: String) -> String {
        // Decoded ASS events are "ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text".
        var text = Substring(line)
        for _ in 0..<8 {
            guard let comma = text.firstIndex(of: ",") else { break }
            text = text[text.index(after: comma)...]
        }
        var result = ""
        var inTag = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character == "{" {
                inTag = true
            } else if character == "}" {
                inTag = false
            } else if !inTag {
                if character == "\\", next < text.endIndex, "Nnh".contains(text[next]) {
                    result.append(text[next] == "h" ? " " : "\n")
                    index = text.index(after: next)
                    continue
                }
                result.append(character)
            }
            index = next
        }
        return result
    }

    /// Converts a palettized subtitle bitmap to a premultiplied RGBA image.
    static func image(of rect: UnsafeMutablePointer<AVSubtitleRect>, canvas: CGSize) -> SubtitleImage? {
        let width = Int(rect.pointee.w), height = Int(rect.pointee.h)
        guard width > 0, height > 0, canvas.width > 0, canvas.height > 0,
              let indices = rect.pointee.data.0, let paletteBytes = rect.pointee.data.1 else { return nil }
        let palette = UnsafeRawPointer(paletteBytes).assumingMemoryBound(to: UInt32.self)
        let colors = Int(rect.pointee.nb_colors)
        let stride = Int(rect.pointee.linesize.0)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = Int(indices[y * stride + x])
                guard index < colors else { continue }
                // FFmpeg's palette entries are 0xAARRGGBB in native byte order.
                let color = palette[index]
                let alpha = UInt32(color >> 24)
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8(((color >> 16) & 0xFF) * alpha / 255)
                pixels[offset + 1] = UInt8(((color >> 8) & 0xFF) * alpha / 255)
                pixels[offset + 2] = UInt8((color & 0xFF) * alpha / 255)
                pixels[offset + 3] = UInt8(alpha)
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        let frame = CGRect(x: CGFloat(rect.pointee.x) / canvas.width, y: CGFloat(rect.pointee.y) / canvas.height,
                           width: CGFloat(width) / canvas.width, height: CGFloat(height) / canvas.height)
        return SubtitleImage(image: image, frame: frame)
    }
}

/// The cues of one subtitle track, in order, trimmed behind the playhead.
struct SubtitleTrackCues {
    private(set) var cues: [SubtitleCue] = []

    mutating func add(_ cue: SubtitleCue) {
        // A new subtitle (or an empty one) replaces whatever was showing.
        if let last = cues.indices.last, cues[last].end > cue.start, cues[last].start <= cue.start {
            cues[last].end = cue.start
        }
        guard !cue.isEmpty else { return }
        let index = cues.lastIndex { $0.start <= cue.start }.map { $0 + 1 } ?? 0
        cues.insert(cue, at: index)
    }

    func cue(at time: Double) -> SubtitleCue? {
        cues.last { $0.start <= time && time < $0.end }
    }

    mutating func dropEnded(before time: Double) {
        cues.removeAll { $0.end < time }
    }
}
