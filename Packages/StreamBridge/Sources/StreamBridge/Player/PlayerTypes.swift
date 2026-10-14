// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics
import FFmpeg
import Foundation

public enum PlayerError: Error, LocalizedError, Sendable, Equatable {
    case noPlayableStreams
    case unsupportedCodec(String)
    /// A live source stopped sending and didn't come back after reconnecting.
    case sourceStopped

    public var errorDescription: String? {
        switch self {
        case .noPlayableStreams: "The stream has no audio or video."
        case .unsupportedCodec(let name): "The stream uses \(name), which can't be played."
        case .sourceStopped: "The channel stopped sending video."
        }
    }
}

/// What to play.
public struct PlayerSource: Sendable {
    public var url: URL
    /// HTTP headers to send, such as `User-Agent` and `Referer`.
    public var headers: [String: String]
    /// Live streams aren't seekable, and their timestamps are smoothed over discontinuities.
    public var isLive: Bool
    /// Where to start a finite stream, in seconds.
    public var startPosition: TimeInterval?
    /// How many seconds to read ahead before starting, or `nil` for the default.
    public var buffer: TimeInterval?
    /// Picks the audio track to start with from the tracks' language tags. The stream's default otherwise.
    public var prefersAudioLanguage: (@Sendable (String?) -> Bool)?
    /// Picks the subtitle track to start with. Subtitles stay off when nothing matches.
    public var prefersSubtitleLanguage: (@Sendable (String?) -> Bool)?

    public init(url: URL, headers: [String: String] = [:], isLive: Bool, startPosition: TimeInterval? = nil,
                buffer: TimeInterval? = nil, prefersAudioLanguage: (@Sendable (String?) -> Bool)? = nil,
                prefersSubtitleLanguage: (@Sendable (String?) -> Bool)? = nil) {
        self.url = url
        self.headers = headers
        self.isLive = isLive
        self.startPosition = startPosition
        self.buffer = buffer
        self.prefersAudioLanguage = prefersAudioLanguage
        self.prefersSubtitleLanguage = prefersSubtitleLanguage
    }
}

/// An audio or subtitle stream of the media.
public struct PlayerTrack: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case audio
        case subtitle
    }

    /// The stream's index in the container.
    public var id: Int32
    public var kind: Kind
    /// The stream's own title, if it has one.
    public var title: String?
    /// The stream's language tag, as the container gives it (`eng`, `fre`, `de`…).
    public var language: String?
    /// The codec's short name (`aac`, `ac3`, `subrip`…).
    public var codec: String
    /// Audio channels; 0 for subtitles.
    public var channels: Int
    public var isSelected: Bool
}

public enum PlayerStatus: Sendable, Equatable {
    case loading
    /// Waiting for data after a seek or because the stream ran dry.
    case buffering
    case playing
    case paused
    /// A finite stream played to its end.
    case ended
    case failed(String)
}

public enum PlayerEvent: Sendable {
    case status(PlayerStatus)
    /// `nil` for live streams.
    case duration(TimeInterval?)
    case tracks([PlayerTrack])
    /// The playback position in seconds, a couple of times a second.
    case time(TimeInterval)
    /// The picture's size in square pixels.
    case videoSize(CGSize)
    case subtitle(SubtitleCue?)
}

/// A copy of a stream's decoding parameters, so decoders can be made on any thread while the demuxer keeps
/// updating its own.
final class StreamParameters: @unchecked Sendable {
    let index: Int32
    let parameters: UnsafeMutablePointer<AVCodecParameters>
    let timeBase: AVRational
    let frameRate: AVRational

    init(stream: UnsafeMutablePointer<AVStream>, frameRate: AVRational) {
        index = stream.pointee.index
        parameters = avcodec_parameters_alloc()
        avcodec_parameters_copy(parameters, stream.pointee.codecpar)
        timeBase = stream.pointee.time_base
        self.frameRate = frameRate
    }

    deinit {
        var parameters: UnsafeMutablePointer<AVCodecParameters>? = parameters
        avcodec_parameters_free(&parameters)
    }

    var codec: String { codecName(parameters.pointee.codec_id) }
}
