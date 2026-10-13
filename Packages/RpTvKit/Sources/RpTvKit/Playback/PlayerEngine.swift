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

    func load(_ item: PlaybackItem)
    func play()
    func pause()
    func seek(to time: TimeInterval)
    func stop()
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

    /// The engine to retry with after `failed` could not play a stream.
    public static func fallback(after failed: PlayerEngineKind) -> PlayerEngineKind? {
        failed == .native ? .vlc : nil
    }
}
