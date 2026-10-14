// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import RpTvKit
import SwiftUI

/// A series' backdrop, poster and facts, Play or Resume, and its episodes season by season with how far each
/// was watched. Episodes are fetched from the provider the first time the series is opened, and again once they're
/// a week old.
struct SeriesDetailView: View {
    let summary: SeriesSummary

    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var series: Series?
    @State private var episodes = SeriesEpisodes()
    @State private var progress: [String: PlaybackProgress] = [:]
    @State private var season: Int?
    @State private var isLoadingDetails = false
    @State private var detailsError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                VStack(alignment: .leading, spacing: 20) {
                    actions
                    if let detailsError {
                        Label(detailsError, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let series {
                        facts(series)
                    }
                    episodeList
                }
                .padding(.horizontal)
                .frame(maxWidth: 760, alignment: .leading)
            }
            .padding(.bottom, 32)
        }
        .navigationTitle(summary.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: summary.stableKey) {
            do {
                for try await series in model.database.observeSeries(sourceID: summary.sourceID, stableKey: summary.stableKey) {
                    self.series = series
                }
            } catch is CancellationError {
            } catch {
                model.alertMessage = error.localizedDescription
            }
        }
        .task(id: summary.stableKey) {
            do {
                for try await episodes in model.database.observeEpisodes(sourceID: summary.sourceID, seriesKey: summary.stableKey) {
                    self.episodes = episodes
                    pickSeason()
                }
            } catch is CancellationError {
            } catch {
                model.alertMessage = error.localizedDescription
            }
        }
        .task(id: summary.stableKey) {
            do {
                for try await progress in model.database.observeEpisodeProgress(sourceID: summary.sourceID,
                                                                                 seriesKey: summary.stableKey) {
                    self.progress = progress
                    pickSeason()
                }
            } catch is CancellationError {
            } catch {
                model.alertMessage = error.localizedDescription
            }
        }
        .task(id: summary.stableKey) { await loadDetails() }
    }

    /// The episode Play starts: the one stopped partway, else the one after the last watched, else the first.
    private var upNext: Episode? { episodes.upNext(progress: progress) }

    // MARK: - Sections

    private var header: some View {
        let posterWidth: CGFloat = sizeClass == .compact ? 110 : 160
        let backdrop = series?.backdropURL ?? summary.posterURL
        let backdropHeight: CGFloat = backdrop == nil ? 60 : sizeClass == .compact ? 220 : 340
        return ZStack(alignment: .bottomLeading) {
            BackdropImage(url: backdrop)
                .frame(height: backdropHeight)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay {
                    LinearGradient(colors: [.clear, Color(.systemBackground)], startPoint: .center, endPoint: .bottom)
                }
            HStack(alignment: .bottom, spacing: 16) {
                PosterImage(url: summary.posterURL, title: summary.name, width: posterWidth)
                    .frame(width: posterWidth)
                    .shadow(radius: 8)
                VStack(alignment: .leading, spacing: 6) {
                    Text(summary.name)
                        .font(.title2.bold())
                        .lineLimit(3)
                    if let line = factsLine {
                        Text(line)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let rating = series?.rating ?? summary.rating {
                        Label(rating.ratingText, systemImage: "star.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Rating \(rating.ratingText)")
                    }
                }
                .padding(.bottom, 4)
            }
            .padding(.horizontal)
            .offset(y: 40)
        }
        .padding(.bottom, 40)
    }

    /// "2020 · Drama · 3 Seasons", leaving out what isn't known.
    private var factsLine: String? {
        let genre = series?.genre?.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) }
        let seasons = episodes.seasonNumbers.count
        let seasonText = seasons == 0 ? nil : seasons == 1 ? "1 Season" : "\(seasons) Seasons"
        let parts = [(series?.year ?? summary.year).map(String.init), genre, seasonText].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                if let upNext { play(upNext) }
            } label: {
                Group {
                    if let upNext {
                        let resumes = progress[upNext.stableKey]?.resumePosition != nil
                        Label("\(resumes ? "Resume" : "Play") \(upNext.code)", systemImage: "play.fill")
                    } else {
                        Label("Play", systemImage: "play.fill")
                    }
                }
                .frame(maxWidth: sizeClass == .compact ? .infinity : 240)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(upNext == nil || series == nil)
            .accessibilityIdentifier("playSeriesButton")

            let isFavorite = model.isFavorite(summary.itemKey)
            Button {
                model.toggleFavorite(summary.itemKey)
            } label: {
                Label(isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: isFavorite ? "star.fill" : "star")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .accessibilityIdentifier("seriesFavoriteButton")

            if let trailer = series?.trailerURL {
                Button {
                    openURL(trailer)
                } label: {
                    Label("Trailer", systemImage: "play.rectangle")
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
        }
    }

    @ViewBuilder private func facts(_ series: Series) -> some View {
        if let plot = series.plot {
            Text(plot)
                .font(.body)
        }
        VStack(alignment: .leading, spacing: 10) {
            fact("Genre", series.genre)
            fact("Director", series.director)
            fact("Cast", series.cast)
        }
    }

    @ViewBuilder private func fact(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline)
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Episodes

    @ViewBuilder private var episodeList: some View {
        let seasons = episodes.seasonNumbers
        if seasons.isEmpty {
            if isLoadingDetails {
                ProgressView("Loading episodes…")
                    .frame(maxWidth: .infinity)
                    .padding(.top)
            } else if detailsError == nil {
                Text("No episodes yet.")
                    .foregroundStyle(.secondary)
            }
        } else {
            let current = season ?? seasons[0]
            VStack(alignment: .leading, spacing: 12) {
                seasonPicker(seasons, current: current)
                if let overview = episodes.season(current)?.overview {
                    Text(overview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(episodes.episodes(inSeason: current)) { episode in
                        EpisodeRow(episode: episode, progress: progress[episode.stableKey], isUpNext: episode == upNext) {
                            play(episode)
                        } onPlayFromStart: {
                            play(episode, fromStart: true)
                        } onSetWatched: { watched in
                            model.setWatched(episode.itemKey, watched)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func seasonPicker(_ seasons: [Int], current: Int) -> some View {
        if seasons.count > 1 {
            Picker("Season", selection: Binding(get: { current }, set: { season = $0 })) {
                ForEach(seasons, id: \.self) { number in
                    Text(seasonName(number)).tag(number)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .font(.title3.bold())
            .fixedSize()
            .accessibilityIdentifier("seasonPicker")
        } else {
            Text(seasonName(current))
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func seasonName(_ number: Int) -> String {
        episodes.season(number)?.name ?? "Season \(number)"
    }

    // MARK: - Actions

    /// Opens on the season of the episode up next, until the user picks another.
    private func pickSeason() {
        let seasons = episodes.seasonNumbers
        if let season, seasons.contains(season) { return }
        season = upNext?.season ?? seasons.first
    }

    private func play(_ episode: Episode, fromStart: Bool = false) {
        guard let series else { return }
        model.play(episode, of: series, from: fromStart ? nil : progress[episode.stableKey]?.resumePosition)
    }

    private func loadDetails() async {
        guard let stored = try? await model.database.series(sourceID: summary.sourceID, stableKey: summary.stableKey),
              stored.needsDetails() else { return }
        isLoadingDetails = true
        defer { isLoadingDetails = false }
        do {
            try await model.refreshDetails(of: stored)
            detailsError = nil
        } catch is CancellationError {
        } catch {
            detailsError = "Couldn't load the episodes: \(error.localizedDescription)"
        }
    }
}

/// An episode: its still with how far it was watched, number, title, length and plot.
private struct EpisodeRow: View {
    let episode: Episode
    let progress: PlaybackProgress?
    let isUpNext: Bool
    let onPlay: () -> Void
    let onPlayFromStart: () -> Void
    let onSetWatched: (Bool) -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let isWatched = progress?.isWatched ?? false
        Button(action: onPlay) {
            HStack(alignment: .top, spacing: 12) {
                EpisodeStill(url: episode.stillURL)
                    .frame(width: sizeClass == .compact ? 140 : 200)
                    .overlay(alignment: .bottom) {
                        if let fraction = progress?.fraction, !isWatched, progress?.resumePosition != nil {
                            WatchProgressBar(fraction: fraction)
                                .padding(6)
                        }
                    }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        Spacer(minLength: 0)
                        if isWatched {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                                .accessibilityLabel("Watched")
                        }
                    }
                    if let details {
                        Text(details)
                            .font(.caption)
                            .foregroundStyle(isUpNext ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    }
                    if let plot = episode.plot {
                        Text(plot)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("episode-\(episode.code)")
        .contextMenu {
            if progress?.resumePosition != nil {
                Button("Play from Beginning", systemImage: "arrow.counterclockwise", action: onPlayFromStart)
            }
            if isWatched {
                Button("Mark as Unwatched", systemImage: "circle") { onSetWatched(false) }
            } else {
                Button("Mark as Watched", systemImage: "checkmark.circle") { onSetWatched(true) }
            }
        }
    }

    private var title: String {
        episode.number.map { "\($0). \(episode.title)" } ?? episode.title
    }

    /// "45m · 12 min left", "Up Next", leaving out what isn't known.
    private var details: String? {
        let runtime = episode.durationSeconds.flatMap { $0 > 0 ? Duration.seconds($0).formatted(.units(allowed: [.hours, .minutes], width: .narrow)) : nil }
        let left = progress?.resumePosition != nil ? progress?.remainingText : nil
        let parts = [isUpNext && progress?.resumePosition == nil ? "Up Next" : nil, runtime, left].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
