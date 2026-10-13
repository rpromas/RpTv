// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import RpTvKit
import SwiftUI

/// Categories in a sidebar, channels in the detail column. Collapses to a stack on iPhone.
struct LiveTVView: View {
    enum CategorySelection: Hashable {
        case all
        case category(Int64)
    }

    @Environment(AppModel.self) private var model
    @State private var categories: [CategorySummary] = []
    @State private var selection: CategorySelection? = .all
    @State private var preferredColumn = NavigationSplitViewColumn.sidebar

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredColumn) {
            List(selection: $selection) {
                NavigationLink(value: CategorySelection.all) {
                    Label("All Channels", systemImage: "square.grid.2x2")
                }
                Section("Categories") {
                    ForEach(categories) { summary in
                        NavigationLink(value: CategorySelection.category(summary.category.id!)) {
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
                ChannelListView(sourceID: sourceID, categoryID: categoryID(for: selection), title: title(for: selection))
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

    private func categoryID(for selection: CategorySelection) -> Int64? {
        if case .category(let id) = selection { id } else { nil }
    }

    private func title(for selection: CategorySelection) -> String {
        switch selection {
        case .all: "All Channels"
        case .category(let id): categories.first { $0.category.id == id }?.category.name ?? "Channels"
        }
    }

    private func refreshActiveSource() async {
        guard let source = model.activeSource else { return }
        do {
            try await model.sync(source)
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

struct ChannelListView: View {
    let sourceID: Int64
    let categoryID: Int64?
    let title: String

    @Environment(AppModel.self) private var model
    @State private var channels: [Channel] = []
    @State private var search = ""
    @State private var hasLoaded = false

    var body: some View {
        List(channels) { channel in
            Button {
                model.play(channel, in: ChannelListContext(sourceID: sourceID, categoryID: categoryID, title: title))
            } label: {
                ChannelRow(channel: channel)
            }
            .buttonStyle(.plain)
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search channels")
        .overlay {
            if hasLoaded, channels.isEmpty {
                if search.isEmpty {
                    ContentUnavailableView("No Channels", systemImage: "tv.slash")
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
        .task(id: QueryKey(sourceID: sourceID, categoryID: categoryID, search: search)) {
            do {
                for try await channels in model.database.observeChannels(sourceID: sourceID, categoryID: categoryID, search: search) {
                    self.channels = channels
                    hasLoaded = true
                }
            } catch is CancellationError {
            } catch {
                model.alertMessage = error.localizedDescription
            }
        }
    }

    private struct QueryKey: Equatable {
        var sourceID: Int64
        var categoryID: Int64?
        var search: String
    }
}

#Preview {
    LiveTVView()
        .environment(AppModel.preview())
}
