// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

public enum PlaybackState: Sendable, Equatable {
    case idle
    case loading
    case playing
    case paused
    case buffering
    case failed(String)
}

public enum PlayerEngineKind: Sendable, Codable, CaseIterable {
    /// AVPlayer: HLS and progressive MP4, with system PiP, AirPlay and Now Playing.
    case native
    /// RpTv's FFmpeg player: everything else (raw MPEG-TS, MKV, RTMP, uncommon codecs).
    case ffmpeg
    /// FFmpeg repackages the stream as local HLS (re-encoding what Apple can't decode) and AVPlayer plays that.
    /// Slower to start than the FFmpeg player, but AirPlay can carry its video. Stands in for the FFmpeg
    /// player while AirPlay is on.
    case bridge
}

extension PlayerEngineKind: RawRepresentable {
    public init?(rawValue: String) {
        switch rawValue {
        case "native": self = .native
        // Saved before the FFmpeg player replaced VLC.
        case "ffmpeg", "vlc": self = .ffmpeg
        case "bridge": self = .bridge
        default: return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .native: "native"
        case .ffmpeg: "ffmpeg"
        case .bridge: "bridge"
        }
    }
}

/// An audio or subtitle track the user can pick.
public struct MediaTrack: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case audio
        case subtitle
    }

    /// Unique within one engine and kind. Not stable across engines.
    public var id: String
    public var kind: Kind
    public var name: String
    public var isSelected: Bool

    public init(id: String, kind: Kind, name: String, isSelected: Bool) {
        self.id = id
        self.kind = kind
        self.name = name
        self.isSelected = isSelected
    }
}

/// How video fills the space it's drawn in.
public enum VideoGravity: String, Sendable, CaseIterable {
    /// The whole picture, letterboxed.
    case fit
    /// Fills the space, cropping the edges.
    case fill
    /// Fills the space, distorting the picture.
    case stretch

    /// The mode after this one, for a button that cycles through them.
    public var next: VideoGravity {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

public enum EnginePreference: Sendable, Codable, CaseIterable {
    case automatic
    case native
    case ffmpeg
}

extension EnginePreference: RawRepresentable {
    public init?(rawValue: String) {
        switch rawValue {
        case "automatic": self = .automatic
        case "native": self = .native
        // Settings and exports from before the FFmpeg player replaced VLC.
        case "ffmpeg", "vlc": self = .ffmpeg
        default: return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .automatic: "automatic"
        case .native: "native"
        case .ffmpeg: "ffmpeg"
        }
    }
}

/// A video player backend. The UI talks to engines only through this protocol.
@MainActor
public protocol PlayerEngine: AnyObject, Observable {
    var kind: PlayerEngineKind { get }
    var state: PlaybackState { get }
    var currentTime: TimeInterval { get }
    /// `nil` for live streams and while unknown.
    var duration: TimeInterval? { get }

    var audioTracks: [MediaTrack] { get }
    var subtitleTracks: [MediaTrack] { get }
    var videoGravity: VideoGravity { get set }
    /// The playback speed, 1 being normal. Kept while paused.
    var rate: Float { get set }
    /// Whether ``startPictureInPicture()`` can be called right now.
    var supportsPictureInPicture: Bool { get }
    var isPictureInPictureActive: Bool { get }

    func load(_ item: PlaybackItem)
    func play()
    func pause()
    func seek(to time: TimeInterval)
    func stop()
    func select(track: MediaTrack)
    func disableSubtitles()
    func startPictureInPicture()
}

/// Picks the engine that most likely plays a URL.
public enum EngineSelector {
    private static let nativeExtensions: Set<String> = ["m3u8", "m3u", "mp4", "m4v", "mov", "m4a", "mp3", "aac"]
    private static let ffmpegExtensions: Set<String> = ["ts", "mkv", "avi", "flv", "wmv", "webm", "mpg", "mpeg", "ogv", "3gp", "divx", "vob"]
    private static let ffmpegSchemes: Set<String> = ["rtmp", "rtmps", "rtsp", "rtp", "udp", "mms", "mmsh"]

    public static func engine(for url: URL, preference: EnginePreference = .automatic) -> PlayerEngineKind {
        switch preference {
        case .native: return .native
        case .ffmpeg: return .ffmpeg
        case .automatic: break
        }
        if let scheme = url.scheme?.lowercased(), ffmpegSchemes.contains(scheme) { return .ffmpeg }
        let pathExtension = url.pathExtension.lowercased()
        if ffmpegExtensions.contains(pathExtension) { return .ffmpeg }
        if nativeExtensions.contains(pathExtension) { return .native }
        // Unknown: try native first; the player falls back to FFmpeg if it fails.
        return .native
    }

    /// The engine to retry with after `failed` could not play a stream. While AirPlay is on (`prefersBridge`),
    /// streams AVPlayer can't open go through the bridge before the FFmpeg player, which can only send sound
    /// over AirPlay.
    public static func fallback(after failed: PlayerEngineKind, prefersBridge: Bool = false) -> PlayerEngineKind? {
        switch failed {
        case .native: prefersBridge ? .bridge : .ffmpeg
        case .bridge: .ffmpeg
        case .ffmpeg: nil
        }
    }
}
