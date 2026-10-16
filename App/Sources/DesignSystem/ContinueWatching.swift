// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import NukeUI
import RpTvKit
import SwiftUI

/// A row of movies or episodes stopped partway through. Tapping one resumes it; empty when there's none.
struct ContinueWatchingShelf: View {
    enum Kind {
        case movies
        case series
    }

    let kind: Kind
    let sourceID: Int64

    @Environment(AppModel.self) private var model
    @State private var entries: [Entry] = []

    var body: some View {
        // A stack rather than a Group: an empty Group has no view to run the task on.
        VStack(spacing: 0) {
            if !entries.isEmpty {
                shelf
            }
        }
        .task(id: TaskKey(sourceID: sourceID, includesLocked: model.includesLocked)) {
            do {
                for try await entries in observe() {
                    withAnimation { self.entries = entries }
                }
            } catch is CancellationError {
            } catch {
                model.alertMessage = error.localizedDescription
            }
        }
    }

    private var shelf: some View {
        // Context menus build their content outside `body`, where reading `@Environment` traps.
        let model = model
        return VStack(alignment: .leading, spacing: 8) {
            Text("Continue Watching")
                .font(.title3.bold())
                .padding(.horizontal)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(entries) { entry in
                        Button {
                            Task { await play(entry) }
                        } label: {
                            ContinueWatchingCard(entry: entry)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Mark as Watched", systemImage: "checkmark.circle") {
                                model.setWatched(entry.key, true)
                            }
                            Button("Remove from Continue Watching", systemImage: "xmark.circle", role: .destructive) {
                                model.removeFromContinueWatching(entry.key)
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.vertical, 8)
        .accessibilityIdentifier("continueWatchingShelf")
    }

    private func play(_ entry: Entry) async {
        switch entry.item {
        case .movie(let movie): await model.resume(movie)
        case .episode(let episode): await model.resume(episode)
        }
    }

    private func observe() -> any AsyncSequence<[Entry], any Error> {
        let database = model.database
        let includesLocked = model.includesLocked
        switch kind {
        case .movies:
            return database.observeContinueWatchingMovies(sourceID: sourceID, includingLocked: includesLocked)
                .map { $0.map(Entry.init(movie:)) }
        case .series:
            return database.observeContinueWatchingEpisodes(sourceID: sourceID, includingLocked: includesLocked)
                .map { $0.map(Entry.init(episode:)) }
        }
    }

    private struct TaskKey: Equatable {
        var sourceID: Int64
        var includesLocked: Bool
    }

    struct Entry: Identifiable, Hashable {
        enum Item: Hashable {
            case movie(ContinueWatchingMovie)
            case episode(ContinueWatchingEpisode)
        }

        var item: Item
        var key: ItemKey
        var title: String
        var subtitle: String?
        var artworkURL: String?
        var progress: PlaybackProgress

        var id: ItemKey { key }

        init(movie: ContinueWatchingMovie) {
            item = .movie(movie)
            key = movie.progress.key
            title = movie.movie.name
            subtitle = movie.progress.remainingText
            artworkURL = movie.artworkURL
            progress = movie.progress
        }

        init(episode: ContinueWatchingEpisode) {
            item = .episode(episode)
            key = episode.progress.key
            title = episode.series.name
            subtitle = [episode.episode.code, episode.progress.remainingText].compactMap { $0 }.joined(separator: " · ")
            artworkURL = episode.artworkURL
            progress = episode.progress
        }
    }
}

/// A wide still with how far playback got, and what it is underneath.
private struct ContinueWatchingCard: View {
    let entry: ContinueWatchingShelf.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            EpisodeStill(url: entry.artworkURL)
                .overlay(alignment: .bottom) {
                    if let fraction = entry.progress.fraction {
                        WatchProgressBar(fraction: fraction)
                            .padding(8)
                    }
                }
                .overlay {
                    Image(systemName: "play.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.ultraThinMaterial, in: .circle)
                }
            Text(entry.title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            if let subtitle = entry.subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 220)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// A 16:9 still, or a plain tile while there's none.
struct EpisodeStill: View {
    let url: String?

    var body: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                LazyImage(url: url.flatMap(URL.init(string:))) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        ZStack {
                            Rectangle().fill(.fill.tertiary)
                            Image(systemName: "play.rectangle")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .processors([.resize(width: 480)])
            }
            .clipShape(.rect(cornerRadius: 10))
            .accessibilityHidden(true)
    }
}

/// How much of a movie or an episode has been watched.
struct WatchProgressBar: View {
    let fraction: Double

    var body: some View {
        Capsule()
            .fill(.white.opacity(0.35))
            .frame(height: 4)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(.tint)
                    .scaleEffect(x: fraction, anchor: .leading)
            }
            .accessibilityElement()
            .accessibilityLabel("Watched")
            .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
    }
}

extension PlaybackProgress {
    /// "42 min left", or `nil` when the length is unknown.
    var remainingText: String? {
        guard let remaining, remaining > 0 else { return nil }
        let rounded = max((remaining / 60).rounded(.up), 1) * 60
        return "\(Duration.seconds(rounded).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))) left"
    }
}
