// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import RpTvKit
import SwiftUI

/// A movie's backdrop, poster and facts, with Play and the trailer. Details are fetched from the provider the
/// first time the movie is opened, and again once they're a week old.
struct MovieDetailView: View {
    let summary: MovieSummary

    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var movie: Movie?
    @State private var isLoadingDetails = false
    @State private var detailsError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                VStack(alignment: .leading, spacing: 20) {
                    actions
                    if isLoadingDetails, movie?.plot == nil {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    }
                    if let detailsError {
                        Label(detailsError, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let movie {
                        facts(movie)
                    }
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
                for try await movie in model.database.observeMovie(sourceID: summary.sourceID, stableKey: summary.stableKey) {
                    self.movie = movie
                }
            } catch is CancellationError {
            } catch {
                model.alertMessage = error.localizedDescription
            }
        }
        .task(id: summary.stableKey) { await loadDetails() }
    }

    // MARK: - Sections

    private var header: some View {
        let posterWidth: CGFloat = sizeClass == .compact ? 110 : 160
        let backdrop = movie?.backdropURL ?? summary.posterURL
        // Without any image, the band only needs to leave room for the poster's top.
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
                    if let line = (movie?.factsLine ?? summary.year.map(String.init)) {
                        Text(line)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let rating = movie?.rating ?? summary.rating {
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

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                if let movie { model.play(movie) }
            } label: {
                Label("Play", systemImage: "play.fill")
                    .frame(maxWidth: sizeClass == .compact ? .infinity : 200)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(movie == nil)
            .accessibilityIdentifier("playMovieButton")

            let isFavorite = model.isFavorite(summary.itemKey)
            Button {
                model.toggleFavorite(summary.itemKey)
            } label: {
                Label(isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: isFavorite ? "star.fill" : "star")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .accessibilityIdentifier("movieFavoriteButton")

            if let trailer = movie?.trailerURL {
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

    @ViewBuilder private func facts(_ movie: Movie) -> some View {
        if let plot = movie.plot {
            Text(plot)
                .font(.body)
        }
        VStack(alignment: .leading, spacing: 10) {
            fact("Genre", movie.genre)
            fact("Director", movie.director)
            fact("Cast", movie.cast)
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

    // MARK: - Loading

    private func loadDetails() async {
        guard let stored = try? await model.database.movie(sourceID: summary.sourceID, stableKey: summary.stableKey),
              stored.needsDetails() else { return }
        isLoadingDetails = true
        defer { isLoadingDetails = false }
        do {
            try await model.refreshDetails(of: stored)
            detailsError = nil
        } catch is CancellationError {
        } catch {
            // The movie still plays without them.
            detailsError = "Couldn't load the details: \(error.localizedDescription)"
        }
    }
}
