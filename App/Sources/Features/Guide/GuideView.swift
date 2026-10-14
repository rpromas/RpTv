// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import RpTvKit
import SwiftUI

/// The TV guide: a timeline grid of the active source's channels, narrowed by the same categories as Live TV.
struct GuideView: View {
    @Environment(AppModel.self) private var model
    @State private var categories: [CategorySummary] = []
    /// `nil` for all channels.
    @State private var categoryID: Int64?
    @State private var channels: [Channel] = []
    @State private var hasLoaded = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Guide")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { SourceToolbar() }
                .safeAreaInset(edge: .top, spacing: 0) {
                    if visibleCategories.count > 1 {
                        CategoryChips(categories: visibleCategories, selection: $categoryID)
                    }
                }
        }
        .task(id: model.activeSource?.id) {
            categoryID = nil
            guard let sourceID = model.activeSource?.id else { return }
            do {
                for try await categories in model.database.observeLiveCategories(sourceID: sourceID) {
                    self.categories = categories
                }
            } catch is CancellationError {
            } catch {
                model.alertMessage = error.localizedDescription
            }
        }
        .onChange(of: model.includesLocked) {
            if let categoryID, !visibleCategories.contains(where: { $0.category.id == categoryID }) { self.categoryID = nil }
        }
        .task(id: ChannelQuery(sourceID: model.activeSource?.id, categoryID: categoryID, includesLocked: model.includesLocked)) {
            guard let sourceID = model.activeSource?.id else { return }
            do {
                for try await channels in model.database.observeChannels(sourceID: sourceID, categoryID: categoryID,
                                                                         includingLocked: model.includesLocked) {
                    self.channels = channels
                    hasLoaded = true
                }
            } catch is CancellationError {
            } catch {
                model.alertMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let source = model.activeSource, let sourceID = source.id {
            if !hasLoaded {
                ProgressView()
            } else if channels.isEmpty {
                ContentUnavailableView("No Channels", systemImage: "tv.slash")
            } else if !channels.contains(where: { $0.guideID != nil }) {
                ContentUnavailableView {
                    Label("No TV Guide", systemImage: "list.bullet.rectangle")
                } description: {
                    Text(model.guideSyncing.contains(sourceID)
                         ? "The guide is downloading."
                         : "None of these channels has guide data. You can set a guide URL for \(source.name) in Settings.")
                }
            } else {
                GuideGrid(sourceID: sourceID, channels: channels, context: context(sourceID: sourceID))
                    .id(sourceID)
            }
        }
    }

    /// The list the player zaps through when a channel is picked here.
    private func context(sourceID: Int64) -> ChannelListContext {
        let title = categories.first { $0.category.id == categoryID }?.category.displayName ?? "All Channels"
        return ChannelListContext(sourceID: sourceID, list: categoryID.map { .category($0) } ?? .all, title: title)
    }

    /// The categories to offer. Locked ones are left out until the PIN opens them in Live TV or Movies.
    private var visibleCategories: [CategorySummary] {
        model.parental.isRestricted ? categories.filter { !$0.category.isLocked } : categories
    }

    private struct ChannelQuery: Equatable {
        var sourceID: Int64?
        var categoryID: Int64?
        var includesLocked: Bool
    }
}

/// A row of capsules along the top: All, then each category.
private struct CategoryChips: View {
    let categories: [CategorySummary]
    @Binding var selection: Int64?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip("All", id: nil)
                ForEach(categories) { summary in
                    chip(summary.category.displayName, id: summary.category.id)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder private func chip(_ title: String, id: Int64?) -> some View {
        if selection == id {
            Button(title) {}
                .buttonStyle(.glassProminent)
                .accessibilityAddTraits(.isSelected)
        } else {
            Button(title) { selection = id }
                .buttonStyle(.glass)
        }
    }
}

#Preview {
    GuideView()
        .environment(AppModel.preview())
}
