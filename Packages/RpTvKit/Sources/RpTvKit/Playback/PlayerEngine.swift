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

public enum PlayerEngineKind: String, Sendable, Codable, CaseIterable {
    /// AVPlayer: HLS and progressive MP4, with system PiP, AirPlay and Now Playing.
    case native
    /// VLCKit: everything else (raw MPEG-TS, MKV, RTMP, uncommon codecs).
    case vlc
    /// FFmpeg repackages the stream as local HLS (re-encoding what Apple can't decode) and AVPlayer plays that.
    /// Slower to start than VLC, but AirPlay can carry its video. Used for VLC streams while AirPlay is on.
    case bridge
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

public enum EnginePreference: String, Sendable, Codable, CaseIterable {
    case automatic
    case native
    case vlc
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
    private static let vlcExtensions: Set<String> = ["ts", "mkv", "avi", "flv", "wmv", "webm", "mpg", "mpeg", "ogv", "3gp", "divx", "vob"]
    private static let vlcSchemes: Set<String> = ["rtmp", "rtmps", "rtsp", "rtp", "udp", "mms", "mmsh"]

    public static func engine(for url: URL, preference: EnginePreference = .automatic) -> PlayerEngineKind {
        switch preference {
        case .native: return .native
        case .vlc: return .vlc
        case .automatic: break
        }
        if let scheme = url.scheme?.lowercased(), vlcSchemes.contains(scheme) { return .vlc }
        let pathExtension = url.pathExtension.lowercased()
        if vlcExtensions.contains(pathExtension) { return .vlc }
        if nativeExtensions.contains(pathExtension) { return .native }
        // Unknown: try native first; the player falls back to VLC if it fails.
        return .native
    }

    /// The engine to retry with after `failed` could not play a stream. While AirPlay is on (`prefersBridge`),
    /// streams AVPlayer can't open go through the bridge before VLC, which can only send sound over AirPlay.
    public static func fallback(after failed: PlayerEngineKind, prefersBridge: Bool = false) -> PlayerEngineKind? {
        switch failed {
        case .native: prefersBridge ? .bridge : .vlc
        case .bridge: .vlc
        case .vlc: nil
        }
    }
}
