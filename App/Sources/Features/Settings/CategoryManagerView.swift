// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import RpTvKit
import SwiftUI

/// A source's categories of one kind: show or hide them, rename them, drag them into order, and lock them.
/// The changes are keyed by the provider's category id, so they survive refreshes.
struct CategoryManagerView: View {
    let sourceID: Int64
    let kind: MediaCategory.Kind

    @Environment(AppModel.self) private var model
    @State private var categories: [CategorySummary] = []
    @State private var hasLoaded = false
    @State private var renaming: MediaCategory?
    @State private var newName = ""
    @State private var needsPIN = false

    var body: some View {
        List {
            Section {
                ForEach(categories) { summary in
                    row(summary.category, itemCount: summary.itemCount)
                }
                .onMove(perform: move)
            } footer: {
                Text(kind == .live
                     ? "Hidden categories and their channels don't show in Live TV, the guide or search. Locked categories ask for the parental PIN."
                     : "Hidden categories and their movies don't show in Movies or search. Locked categories ask for the parental PIN.")
            }
        }
        .navigationTitle(kind == .live ? "Live TV Categories" : "Movie Categories")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if categories.count > 1 {
                ToolbarItem(placement: .primaryAction) { EditButton() }
            }
        }
        .overlay {
            if hasLoaded, categories.isEmpty {
                ContentUnavailableView("No Categories", systemImage: "square.stack.3d.up.slash")
            }
        }
        .task {
            do {
                for try await categories in model.database.observeAllCategories(sourceID: sourceID, kind: kind) {
                    self.categories = categories
                    hasLoaded = true
                }
            } catch is CancellationError {
            } catch {
                model.alertMessage = error.localizedDescription
            }
        }
        .alert("Rename Category", isPresented: .init(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(renaming?.name ?? "Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let category = renaming { rename(category, to: newName) }
            }
        } message: {
            if let renaming {
                Text("Leave empty to use the provider's name, \(renaming.name).")
            }
        }
        .alert("Set a PIN First", isPresented: $needsPIN) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Turn on Parental Controls in Settings to lock categories.")
        }
    }

    private func row(_ category: MediaCategory, itemCount: Int) -> some View {
        Toggle(isOn: Binding(get: { !category.isHidden }, set: { shown in setHidden(category, !shown) })) {
            HStack(spacing: 8) {
                if category.isLocked {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Locked")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.displayName)
                        .foregroundStyle(category.isHidden ? .secondary : .primary)
                    Group {
                        if category.customName != nil {
                            Text("\(category.name) · ^[\(itemCount) item](inflect: true)")
                        } else {
                            Text("^[\(itemCount) item](inflect: true)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier("category-\(category.remoteID)")
        .swipeActions {
            Button(category.isLocked ? "Unlock" : "Lock", systemImage: category.isLocked ? "lock.open" : "lock") {
                toggleLock(category)
            }
            .tint(.orange)
            Button("Rename", systemImage: "pencil") { startRenaming(category) }
                .tint(.blue)
        }
        .contextMenu {
            Button("Rename", systemImage: "pencil") { startRenaming(category) }
            if category.customName != nil {
                Button("Use Provider's Name", systemImage: "arrow.uturn.backward") { rename(category, to: "") }
            }
            Button(category.isHidden ? "Show" : "Hide", systemImage: category.isHidden ? "eye" : "eye.slash") {
                setHidden(category, !category.isHidden)
            }
            Button(category.isLocked ? "Unlock" : "Lock", systemImage: category.isLocked ? "lock.open" : "lock") {
                toggleLock(category)
            }
        }
    }

    private func startRenaming(_ category: MediaCategory) {
        newName = category.displayName
        renaming = category
    }

    private func rename(_ category: MediaCategory, to name: String) {
        let database = model.database
        model.perform {
            try await database.renameCategory(sourceID: category.sourceID, kind: category.kind, remoteID: category.remoteID, to: name)
        }
    }

    private func setHidden(_ category: MediaCategory, _ hidden: Bool) {
        update(category) { $0.isHidden = hidden }
    }

    /// Locking and unlocking are parental settings, so they need the PIN, unless it was entered in this session.
    private func toggleLock(_ category: MediaCategory) {
        guard model.parental.hasPIN else {
            needsPIN = true
            return
        }
        Task {
            if !model.parental.isUnlocked {
                guard await model.authorize(reason: "Enter your PIN to change which categories are locked.") else { return }
            }
            let locked = !category.isLocked
            update(category) { $0.isLocked = locked }
        }
    }

    private func update(_ category: MediaCategory, _ modify: @escaping @Sendable (inout MediaCategory) -> Void) {
        let database = model.database
        model.perform {
            try await database.updateCategory(sourceID: category.sourceID, kind: category.kind, remoteID: category.remoteID, modify)
        }
    }

    private func move(from offsets: IndexSet, to destination: Int) {
        categories.move(fromOffsets: offsets, toOffset: destination)
        let remoteIDs = categories.map(\.category.remoteID)
        let database = model.database
        model.perform {
            try await database.reorderCategories(sourceID: sourceID, kind: kind, remoteIDs: remoteIDs)
        }
    }
}

#Preview {
    NavigationStack {
        CategoryManagerView(sourceID: 1, kind: .live)
    }
    .environment(AppModel.preview())
}
