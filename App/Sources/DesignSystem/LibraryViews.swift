// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import RpTvKit
import SwiftUI

/// One of a source's movie or series lists.
enum LibraryList: Hashable {
    case all
    case category(Int64)
    case favorites
    case recent
}

/// "All", "Favorites", "Recent" and one chip per category, scrolling sideways.
struct LibraryChips: View {
    let categories: [CategorySummary]
    @Binding var selection: LibraryList
    /// Starts the chips' accessibility identifiers, such as "movie" for "movieFavoritesChip".
    let identifierPrefix: String
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    chip("All", list: .all)
                    chip("Favorites", list: .favorites)
                        .accessibilityIdentifier("\(identifierPrefix)FavoritesChip")
                    chip("Recent", list: .recent)
                        .accessibilityIdentifier("\(identifierPrefix)RecentChip")
                    ForEach(categories) { summary in
                        chip(summary.category.displayName, list: .category(summary.category.id!),
                             isLocked: summary.category.isLocked && model.parental.isRestricted)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
            // A horizontal scroll view takes all the height it's offered: keep the bar to its chips.
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: selection) { _, list in
                withAnimation { proxy.scrollTo(list, anchor: .center) }
            }
        }
    }

    @ViewBuilder private func chip(_ title: String, list: LibraryList, isLocked: Bool = false) -> some View {
        let button = Button { selection = list } label: {
            if isLocked {
                Label(title, systemImage: "lock.fill")
            } else {
                Text(title)
            }
        }
            .controlSize(.small)
            .accessibilityAddTraits(selection == list ? .isSelected : [])
            .id(list)
        if selection == list {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.glass)
        }
    }
}

/// A poster with its title and year, the rating in one corner and a star in the other for favorites.
struct PosterCell: View {
    let title: String
    let posterURL: String?
    var rating: Double?
    var year: Int?
    let posterWidth: CGFloat
    var isFavorite = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterImage(url: posterURL, title: title, width: posterWidth)
                .overlay(alignment: .topTrailing) {
                    if let rating {
                        Label(rating.ratingText, systemImage: "star.fill")
                            .font(.caption2.weight(.semibold))
                            .labelStyle(.titleAndIcon)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: .capsule)
                            .padding(5)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .padding(5)
                            .background(.ultraThinMaterial, in: .circle)
                            .padding(5)
                            .accessibilityLabel("Favorite")
                    }
                }
            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(2)
            if let year {
                Text(String(year))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
