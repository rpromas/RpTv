// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import RpTvKit
import SwiftUI

/// Searches channels, movies and guide programmes across every source.
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results = SearchResults()
    /// The query `results` are for, so "no results" isn't shown for a query still being searched.
    @State private var resultsQuery = ""
    @State private var selection: ProgrammeSelection?
    @State private var pendingPlay: (channel: Channel, catchup: Programme?)?

    var body: some View {
        NavigationStack {
            NowNextReader(database: model.database, channelIDs: results.channels.compactMap(\.channel.id)) { nowNext, now in
                List {
                    if !results.channels.isEmpty {
                        Section("Channels") {
                            ForEach(results.channels) { hit in
                                channelRow(hit, nowNext: hit.channel.id.flatMap { nowNext[$0] }, now: now)
                            }
                        }
                    }
                    if !results.movies.isEmpty {
                        Section("Movies") {
                            ForEach(results.movies) { hit in
                                movieRow(hit)
                            }
                        }
                    }
                    if !results.programmes.isEmpty {
                        Section("Programmes") {
                            ForEach(results.programmes) { hit in
                                programmeRow(hit)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .overlay { emptyView }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Channels, movies and programmes")
            .navigationDestination(for: MovieSummary.self) { movie in
                MovieDetailView(summary: movie)
            }
            .task(id: SearchKey(query: query, includesLocked: model.includesLocked)) { await search(query) }
            .sheet(item: $selection, onDismiss: playPending) { selection in
                ProgrammeDetailView(channel: selection.channel, programmeID: selection.programmeID) { catchup in
                    pendingPlay = (selection.channel, catchup)
                    self.selection = nil
                }
            }
        }
    }

    @ViewBuilder private var emptyView: some View {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView("Search", systemImage: "magnifyingglass",
                                   description: Text("Find channels, movies and programmes in all your sources."))
        } else if resultsQuery == query, results.isEmpty {
            ContentUnavailableView.search(text: query)
        }
    }

    private func channelRow(_ hit: SearchResults.ChannelHit, nowNext: NowNext?, now: Date) -> some View {
        Button {
            model.play(hit.channel, in: .allChannels(of: hit.channel.sourceID))
        } label: {
            ChannelRow(channel: hit.channel, nowNext: nowNext, now: now, isFavorite: model.isFavorite(hit.channel.itemKey),
                       sourceName: hit.sourceName)
        }
        .buttonStyle(.plain)
        .favoriteActions(for: hit.channel.itemKey)
    }

    private func movieRow(_ hit: SearchResults.MovieHit) -> some View {
        NavigationLink(value: hit.movie) {
            HStack(spacing: 14) {
                PosterImage(url: hit.movie.posterURL, title: hit.movie.name, width: 40)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(hit.movie.name)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        if model.isFavorite(hit.movie.itemKey) {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                                .accessibilityLabel("Favorite")
                        }
                    }
                    if let year = hit.movie.year {
                        Text(String(year))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(hit.sourceName)
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                }
            }
        }
        .favoriteActions(for: hit.movie.itemKey)
    }

    private func programmeRow(_ hit: SearchResults.ProgrammeHit) -> some View {
        Button {
            selection = ProgrammeSelection(channel: hit.channel, programmeID: hit.programme.id!)
        } label: {
            HStack(spacing: 14) {
                ChannelLogo(url: hit.channel.logoURL, name: hit.channel.name)
                    .frame(width: 56, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(hit.programme.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text("\(hit.channel.name) · \(Self.when(hit.programme.start))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(hit.sourceName)
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func search(_ query: String) async {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = SearchResults()
            resultsQuery = query
            return
        }
        // Wait for a pause in typing.
        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
        do {
            for try await results in model.database.observeSearch(query, includingLocked: model.includesLocked) {
                self.results = results
                resultsQuery = query
            }
        } catch is CancellationError {
        } catch {
            model.alertMessage = error.localizedDescription
        }
    }

    private func playPending() {
        guard let pendingPlay else { return }
        self.pendingPlay = nil
        model.play(pendingPlay.channel, in: .allChannels(of: pendingPlay.channel.sourceID), catchup: pendingPlay.catchup)
    }

    /// "Now", "20:00", or "Thu 20:00" for another day.
    private static func when(_ start: Date) -> String {
        if start <= .now { return "Now" }
        if Calendar.current.isDateInToday(start) { return start.formatted(.dateTime.hour().minute()) }
        return start.formatted(.dateTime.weekday().hour().minute())
    }

    private struct SearchKey: Equatable {
        var query: String
        var includesLocked: Bool
    }

    private struct ProgrammeSelection: Identifiable {
        var channel: Channel
        var programmeID: Int64
        var id: Int64 { programmeID }
    }
}

#Preview {
    SearchView()
        .environment(AppModel.preview())
}
