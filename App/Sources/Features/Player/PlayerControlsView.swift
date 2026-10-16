// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import RpTvKit
import SwiftUI

/// The controls drawn over the video. `compact` (the docked portrait player) leaves out the top bar.
struct PlayerControlsView: View {
    let session: PlayerSession
    let compact: Bool
    let onClose: () -> Void
    /// Switches between the docked and full-screen layouts on iPhone. `nil` where that isn't possible.
    let onToggleFullScreen: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            if !compact {
                PlayerTopBar(session: session, showsTitle: true, showsAspect: true, onClose: onClose)
            }
            Spacer(minLength: 0)
            if !session.coordinator.state.isFailed {
                PlayerTransport(session: session, compact: compact)
            }
            Spacer(minLength: 0)
            PlayerBottomBar(session: session, compact: compact, onToggleFullScreen: onToggleFullScreen)
        }
        .padding(compact ? 8 : 16)
    }
}

/// Close, the channel title, and the actions that apply to the whole stream.
struct PlayerTopBar: View {
    let session: PlayerSession
    let showsTitle: Bool
    let showsAspect: Bool
    let onClose: () -> Void

    @Environment(PlayerChrome.self) private var chrome

    var body: some View {
        HStack(spacing: 12) {
            PlayerIconButton(title: "Close", systemImage: "xmark", action: onClose)
            if showsTitle {
                NowPlayingTitle(session: session, fallback: session.context?.title)
                    .shadow(color: .black.opacity(0.4), radius: 6)
            }
            Spacer(minLength: 8)
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    if let item = session.channel?.itemKey ?? session.movie?.itemKey ?? session.episode?.seriesItemKey {
                        FavoriteButton(item: item)
                    }
                    if let engine = session.coordinator.engine {
                        TracksMenu(engine: engine)
                        if showsAspect { AspectButton(engine: engine) }
                        PictureInPictureButton(engine: engine)
                    }
                    RoutePickerButton()
                    PlayerIconButton(title: "Lock Controls", systemImage: "lock.open") { chrome.lock() }
                }
            }
        }
    }
}

/// Logo, number and name, with a second line underneath and, for a programme on air, how far into it we are.
struct ChannelTitle: View {
    let channel: Channel
    let subtitle: String?
    var progress: Double?
    var logoSize = CGSize(width: 48, height: 34)

    var body: some View {
        HStack(spacing: 12) {
            ChannelLogo(url: channel.logoURL, name: channel.name)
                .frame(width: logoSize.width, height: logoSize.height)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.numberedName)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let progress {
                    ProgrammeProgressBar(progress: progress)
                        .frame(width: 120)
                        .padding(.top, 2)
                }
            }
            .lineLimit(1)
        }
    }
}

/// The title of what's playing, with the archived programme or the one on air. `fallback` is the second line
/// when the guide has nothing.
struct NowPlayingTitle: View {
    let session: PlayerSession
    let fallback: String?
    var logoSize = CGSize(width: 48, height: 34)

    var body: some View {
        if let movie = session.movie {
            MovieTitle(movie: movie, posterWidth: logoSize.height)
        } else if let episode = session.episode, let series = session.series {
            EpisodeTitle(episode: episode, series: series, posterWidth: logoSize.height)
        } else if let channel = session.channel {
            if let programme = session.catchupProgramme {
                ChannelTitle(channel: channel,
                             subtitle: "\(programme.title) · \(programme.start.formatted(.dateTime.weekday().hour().minute()))",
                             logoSize: logoSize)
            } else {
                let channelIDs = channel.id.map { [$0] } ?? []
                NowNextReader(database: session.database, channelIDs: channelIDs) { nowNext, now in
                    let current = channel.id.flatMap { nowNext[$0]?.now }
                    ChannelTitle(channel: channel, subtitle: current?.title ?? fallback,
                                 progress: current?.progress(at: now), logoSize: logoSize)
                }
            }
        }
    }
}

/// A small poster, the movie's name, and its year and genre.
struct MovieTitle: View {
    let movie: Movie
    /// The poster is half as tall again.
    var posterWidth: CGFloat = 34

    var body: some View {
        HStack(spacing: 12) {
            PosterImage(url: movie.posterURL, title: "", width: posterWidth)
                .frame(width: posterWidth)
            VStack(alignment: .leading, spacing: 2) {
                Text(movie.name)
                    .font(.headline)
                if let subtitle = movie.factsLine {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
    }
}

/// A small poster, the series' name, and which episode this is.
struct EpisodeTitle: View {
    let episode: Episode
    let series: Series
    /// The poster is half as tall again.
    var posterWidth: CGFloat = 34

    var body: some View {
        HStack(spacing: 12) {
            PosterImage(url: series.posterURL, title: "", width: posterWidth)
                .frame(width: posterWidth)
            VStack(alignment: .leading, spacing: 2) {
                Text(series.name)
                    .font(.headline)
                Text("\(episode.code) · \(episode.title)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }
    }
}

/// Play/pause in the middle, between channel up/down for live streams or ±10 s skips for ones with an end.
struct PlayerTransport: View {
    let session: PlayerSession
    let compact: Bool

    @Environment(PlayerChrome.self) private var chrome

    var body: some View {
        let sideSize: CGFloat = compact ? 36 : 44
        GlassEffectContainer(spacing: 24) {
            HStack(spacing: compact ? 28 : 48) {
                let engine = session.coordinator.engine
                // A movie or an episode skips even before its length is known.
                if engine?.duration != nil || session.isOnDemand {
                    PlayerIconButton(title: "Back 10 Seconds", systemImage: "gobackward.10", size: sideSize) {
                        if let engine { skip(engine, by: -10) }
                    }
                    PlayPauseButton(engine: engine, size: compact ? 48 : 60)
                    PlayerIconButton(title: "Forward 10 Seconds", systemImage: "goforward.10", size: sideSize) {
                        if let engine { skip(engine, by: 10) }
                    }
                } else {
                    PlayerIconButton(title: "Previous Channel", systemImage: "backward.end.fill", size: sideSize) {
                        session.zap(by: -1)
                    }
                    .disabled(session.zapList.neighbor(-1) == nil)
                    .accessibilityIdentifier("previousChannelButton")
                    PlayPauseButton(engine: session.coordinator.engine, size: compact ? 48 : 60)
                    PlayerIconButton(title: "Next Channel", systemImage: "forward.end.fill", size: sideSize) {
                        session.zap(by: 1)
                    }
                    .disabled(session.zapList.neighbor(1) == nil)
                    .accessibilityIdentifier("nextChannelButton")
                }
            }
        }
    }

    private func skip(_ engine: any PlayerEngine, by seconds: TimeInterval) {
        engine.seek(to: max(engine.currentTime + seconds, 0))
        chrome.interacted()
    }
}

struct PlayPauseButton: View {
    let engine: (any PlayerEngine)?
    let size: CGFloat

    @Environment(PlayerChrome.self) private var chrome

    var body: some View {
        let state = engine?.state ?? .loading
        let isRunning = state == .playing || state == .buffering
        Button {
            if isRunning { engine?.pause() } else { engine?.play() }
            chrome.interacted()
        } label: {
            ZStack {
                if state == .loading || state == .buffering {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                } else {
                    Image(systemName: isRunning ? "pause.fill" : "play.fill")
                        .font(.system(size: size * 0.45, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: size, height: size)
            .contentShape(.circle)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(isRunning ? "Pause" : "Play")
        .accessibilityIdentifier("playPauseButton")
    }
}

/// The glass bar along the bottom: LIVE or the scrubber, then the per-layout extras.
struct PlayerBottomBar: View {
    let session: PlayerSession
    let compact: Bool
    let onToggleFullScreen: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            if let engine = session.coordinator.engine, let duration = engine.duration {
                Scrubber(engine: engine, duration: duration)
                SpeedMenu(engine: engine)
            } else if session.catchupProgramme != nil {
                CatchupBadge()
                Spacer(minLength: 0)
            } else if session.isOnDemand {
                Spacer(minLength: 0)
            } else {
                LiveBadge(isPaused: session.coordinator.state == .paused)
                Spacer(minLength: 0)
            }
            if session.catchupProgramme != nil {
                Button("Go Live", systemImage: "dot.radiowaves.left.and.right") { session.goLive() }
                    .font(.caption.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                    .accessibilityIdentifier("goLiveButton")
            }
            if let onToggleFullScreen {
                PlayerIconButton(
                    title: compact ? "Full Screen" : "Exit Full Screen",
                    systemImage: compact ? "arrow.up.backward.and.arrow.down.forward" : "arrow.down.forward.and.arrow.up.backward",
                    glass: false,
                    action: onToggleFullScreen
                )
            }
        }
        .padding(.horizontal, compact ? 12 : 18)
        .padding(.vertical, compact ? 2 : 6)
        .glassEffect(.regular, in: .capsule)
    }
}

/// Shown over the video when a stream can't be played. Offers the next channel, since dead channels are common.
struct PlaybackFailureView: View {
    let message: String
    let compact: Bool
    let onRetry: () -> Void
    let onNextChannel: (() -> Void)?

    var body: some View {
        VStack(spacing: compact ? 6 : 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(compact ? .title2 : .largeTitle)
                .foregroundStyle(.secondary)
            Text("Can't Play This Stream")
                .font(compact ? .headline : .title2.bold())
            Text(message)
                .font(compact ? .caption : .body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(compact ? 2 : 4)
            HStack(spacing: 12) {
                Button("Try Again", action: onRetry)
                if let onNextChannel {
                    Button("Next Channel", action: onNextChannel)
                }
            }
            .buttonStyle(.glass)
            .controlSize(compact ? .small : .regular)
            .padding(.top, compact ? 2 : 8)
        }
        .padding()
        .frame(maxWidth: 420)
    }
}

extension PlaybackState {
    var isFailed: Bool {
        if case .failed = self { true } else { false }
    }
}

extension Channel {
    /// "101 · BBC One", or just the name when there's no number.
    var numberedName: String {
        number.map { "\($0) · \(name)" } ?? name
    }
}
