// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import RpTvKit
import SwiftUI

/// Categories in a sidebar, channels in the detail column. Collapses to a stack on iPhone.
struct LiveTVView: View {
    @Environment(AppModel.self) private var model
    @State private var categories: [CategorySummary] = []
    @State private var selection: ChannelList? = .all
    @State private var preferredColumn = NavigationSplitViewColumn.sidebar

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredColumn) {
            List(selection: $selection) {
                Section {
                    NavigationLink(value: ChannelList.favorites) {
                        Label("Favorites", systemImage: "star")
                    }
                    .accessibilityIdentifier("favoritesList")
                    NavigationLink(value: ChannelList.recent) {
                        Label("Recent", systemImage: "clock")
                    }
                    .accessibilityIdentifier("recentList")
                    NavigationLink(value: ChannelList.all) {
                        Label("All Channels", systemImage: "square.grid.2x2")
                    }
                }
                Section("Categories") {
                    ForEach(categories) { summary in
                        NavigationLink(value: ChannelList.category(summary.category.id!)) {
                            LabeledContent(summary.category.name) {
                                Text(summary.itemCount.formatted())
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
            .navigationTitle(model.activeSource?.name ?? "Live TV")
            .toolbar { SourceToolbar() }
            .refreshable { await refreshActiveSource() }
        } detail: {
            if let source = model.activeSource, let sourceID = source.id, let selection {
                ChannelListView(context: ChannelListContext(sourceID: sourceID, list: selection, title: title(for: selection)))
                    .id(selection)
            } else {
                ContentUnavailableView("Pick a Category", systemImage: "tv")
            }
        }
        .task(id: model.activeSource?.id) {
            guard let sourceID = model.activeSource?.id else { return }
            do {
                for try await categories in model.database.observeLiveCategories(sourceID: sourceID) {
                    self.categories = categories
                }
            } catch {
                model.alertMessage = error.localizedDescription
            }
        }
        .onChange(of: model.activeSource?.id) {
            selection = .all
            preferredColumn = .sidebar
        }
    }

    private func title(for selection: ChannelList) -> String {
        switch selection {
        case .all: "All Channels"
        case .category(let id): categories.first { $0.category.id == id }?.category.name ?? "Channels"
        case .favorites: "Favorites"
        case .recent: "Recent"
        }
    }

    private func refreshActiveSource() async {
        guard let source = model.activeSource else { return }
        do {
            try await model.sync(source)
            model.refreshGuideInBackground(source, force: false)
        } catch {
            model.alertMessage = error.localizedDescription
        }
    }
}

/// Switch between sources and see refresh progress.
struct SourceToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if let id = model.activeSource?.id, model.syncPhases[id] != nil {
                ProgressView()
            } else if model.sources.count > 1 {
                Menu {
                    Picker("Source", selection: Binding(
                        get: { model.activeSource?.id },
                        set: { model.activeSourceID = $0 }
                    )) {
                        ForEach(model.sources) { source in
                            Text(source.name).tag(source.id)
                        }
                    }
                } label: {
                    Label("Source", systemImage: "rectangle.stack")
                }
            }
        }
    }
}

/// The channels of one list. Favorites can be reordered by dragging; All Channels and categories can be searched.
struct ChannelListView: View {
    let context: ChannelListContext

    @Environment(AppModel.self) private var model
    @State private var channels: [Channel] = []
    @State private var search = ""
    @State private var hasLoaded = false

    var body: some View {
        NowNextReader(database: model.database, channelIDs: channels.compactMap(\.id)) { nowNext, now in
            List {
                ForEach(channels) { channel in
                    Button {
                        model.play(channel, in: context)
                    } label: {
                        ChannelRow(channel: channel, nowNext: channel.id.flatMap { nowNext[$0] }, now: now,
                                   isFavorite: context.list != .favorites && model.isFavorite(channel.itemKey))
                    }
                    .buttonStyle(.plain)
                    .favoriteActions(for: channel.itemKey)
                }
                .onMove(perform: context.list == .favorites ? move(from:to:) as (IndexSet, Int) -> Void : nil)
            }
            .listStyle(.plain)
        }
        .navigationTitle(context.title)
        .navigationBarTitleDisplayMode(.inline)
        .modifier(SearchableIf(isSearchable: isSearchable, text: $search))
        .toolbar { editToolbar }
        .overlay {
            if hasLoaded, channels.isEmpty {
                emptyView
            }
        }
        .task(id: QueryKey(context: context, search: search)) {
            do {
                for try await channels in model.database.observeChannels(sourceID: context.sourceID, list: context.list,
                                                                         search: isSearchable ? search : "") {
                    self.channels = channels
                    hasLoaded = true
                }
            } catch is CancellationError {
            } catch {
                model.alertMessage = error.localizedDescription
            }
        }
    }

    /// Reordering favorites by dragging also works without it, but this makes it discoverable.
    @ToolbarContentBuilder private var editToolbar: some ToolbarContent {
        if context.list == .favorites, channels.count > 1 {
            ToolbarItem(placement: .primaryAction) { EditButton() }
        }
    }

    private var isSearchable: Bool {
        switch context.list {
        case .all, .category: true
        case .favorites, .recent: false
        }
    }

    @ViewBuilder private var emptyView: some View {
        switch context.list {
        case .favorites:
            ContentUnavailableView("No Favorites", systemImage: "star",
                                   description: Text("Swipe right on a channel, or touch and hold it, to add it to your favorites."))
        case .recent:
            ContentUnavailableView("Nothing Watched Yet", systemImage: "clock",
                                   description: Text("Channels you watch appear here."))
        case .all, .category:
            if search.isEmpty {
                ContentUnavailableView("No Channels", systemImage: "tv.slash")
            } else {
                ContentUnavailableView.search(text: search)
            }
        }
    }

    private struct QueryKey: Equatable {
        var context: ChannelListContext
        var search: String
    }

    private func move(from offsets: IndexSet, to destination: Int) {
        channels.move(fromOffsets: offsets, toOffset: destination)
        let reordered = channels
        Task { await model.reorderFavorites(reordered, sourceID: context.sourceID) }
    }
}

/// `.searchable`, only when the list can be searched.
private struct SearchableIf: ViewModifier {
    let isSearchable: Bool
    @Binding var text: String

    func body(content: Content) -> some View {
        if isSearchable {
            content.searchable(text: $text, prompt: "Search channels")
        } else {
            content
        }
    }
}

#Preview {
    LiveTVView()
        .environment(AppModel.preview())
}
