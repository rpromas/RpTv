// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// What the bridge does with each stream: pass it through untouched where Apple's players can decode it,
/// re-encode it where they can't. Codecs are FFmpeg codec names (`AVCodecDescriptor.name`).
public struct BridgePlan: Sendable, Equatable {
    public enum Video: Sendable, Equatable {
        case copy
        /// Decode with FFmpeg and encode to H.264 with VideoToolbox, deinterlacing first if needed.
        case transcode(deinterlace: Bool)
    }

    public enum Audio: Sendable, Equatable {
        case copy
        /// Decode with FFmpeg and encode to AAC with AudioToolbox.
        case transcode
    }

    public enum SegmentFormat: String, Sendable {
        /// MPEG-TS segments: what most IPTV already is, so copying H.264 costs nothing.
        case mpegts
        /// Fragmented MP4, which Apple requires for HEVC.
        case fmp4
    }

    public var video: Video?
    public var audio: Audio?
    public var segmentFormat: SegmentFormat

    /// Video codecs AVPlayer and Apple TV decode from HLS.
    static let copyableVideo: Set<String> = ["h264", "hevc"]
    /// Audio that's copied. HLS also allows AC-3, E-AC-3 and MP3, but streams with them didn't start on an Apple
    /// TV over AirPlay, while AAC works everywhere and re-encoding audio is cheap. `aac_latm` (common on DVB)
    /// isn't plain AAC, so it's re-encoded too.
    static let copyableAudio: Set<String> = ["aac"]

    /// - Parameters:
    ///   - videoCodec: The video stream's codec, or `nil` for radio streams.
    ///   - interlaced: Whether the video is interlaced. HLS only allows progressive video, and iPhone and Apple TV
    ///     fail on interlaced H.264 (1080i broadcast channels), so interlaced video is always deinterlaced and
    ///     re-encoded, even in a codec that could otherwise be copied.
    ///   - audioCodec: The audio stream's codec, or `nil` when there is none.
    public init(videoCodec: String?, interlaced: Bool, audioCodec: String?) {
        video = videoCodec.map { codec in
            Self.copyableVideo.contains(codec) && !interlaced ? .copy : .transcode(deinterlace: interlaced)
        }
        audio = audioCodec.map { Self.copyableAudio.contains($0) ? .copy : .transcode }
        segmentFormat = videoCodec == "hevc" && video == .copy ? .fmp4 : .mpegts
    }

    /// True when nothing needs re-encoding.
    public var isRemuxOnly: Bool {
        if case .transcode = video { return false }
        return audio != .transcode
    }
}
