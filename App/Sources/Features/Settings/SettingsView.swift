// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import RpTvKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var isAddingSource = false
    @State private var sourcePendingDeletion: Source?
    @State private var detailSourceID: Int64?

    var body: some View {
        NavigationStack {
            List {
                Section("Sources") {
                    ForEach(model.sources) { source in
                        SourceRow(source: source) { detailSourceID = source.id }
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    sourcePendingDeletion = source
                                }
                                Button("Refresh", systemImage: "arrow.clockwise") {
                                    refresh(source)
                                }
                                .tint(.blue)
                            }
                            .contextMenu {
                                Button("Details", systemImage: "info.circle") { detailSourceID = source.id }
                                Button("Refresh", systemImage: "arrow.clockwise") { refresh(source) }
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    sourcePendingDeletion = source
                                }
                            }
                    }
                    Button("Add Source", systemImage: "plus") {
                        isAddingSource = true
                    }
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.versionString)
                    NavigationLink("Acknowledgements") { AcknowledgementsView() }
                } header: {
                    Text("About")
                } footer: {
                    Text("RpTv is free, open-source software under the Mozilla Public License 2.0. It is a player only and doesn't provide any channels or content.")
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(item: $detailSourceID) { id in
                SourceDetailView(sourceID: id)
            }
            .sheet(isPresented: $isAddingSource) {
                AddSourceView()
            }
            .confirmationDialog(
                "Delete \(sourcePendingDeletion?.name ?? "source")?",
                isPresented: .init(get: { sourcePendingDeletion != nil }, set: { if !$0 { sourcePendingDeletion = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let source = sourcePendingDeletion {
                        Task { await model.delete(source) }
                    }
                }
            } message: {
                Text("Its channels and saved login will be removed from this device.")
            }
        }
    }

    private func refresh(_ source: Source) {
        Task {
            do {
                try await model.sync(source)
            } catch {
                model.alertMessage = error.localizedDescription
            }
        }
    }
}

private struct SourceRow: View {
    let source: Source
    let showDetails: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: source.kind == .xtream ? "server.rack" : "list.bullet.rectangle")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(source.name)
                        .font(.body.weight(.medium))
                    if source.id == model.activeSource?.id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .accessibilityLabel("Active")
                    }
                }
                status
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let id = source.id, model.syncPhases[id] != nil {
                ProgressView()
            }
            Button("Details", systemImage: "info.circle", action: showDetails)
                .labelStyle(.iconOnly)
                .font(.title3)
                .buttonStyle(.borderless)
        }
        .contentShape(.rect)
        .onTapGesture { model.activeSourceID = source.id }
    }

    @ViewBuilder private var status: some View {
        if let error = source.lastSyncError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(2)
        } else if let date = source.lastSyncedAt {
            Text("Updated \(date, format: .relative(presentation: .named))")
        } else {
            Text("Never updated")
        }
    }
}

private struct AcknowledgementsView: View {
    private let libraries: [(name: String, license: String, url: String)] = [
        ("GRDB.swift", "MIT License", "https://github.com/groue/GRDB.swift"),
        ("Nuke", "MIT License", "https://github.com/kean/Nuke"),
        ("VLCKit", "LGPL 2.1", "https://code.videolan.org/videolan/VLCKit"),
    ]

    var body: some View {
        List {
            Section {
                ForEach(libraries, id: \.name) { library in
                    Link(destination: URL(string: library.url)!) {
                        LabeledContent(library.name, value: library.license)
                    }
                }
            } footer: {
                Text("VLCKit is linked dynamically. You can rebuild RpTv from its source code with a modified version of VLCKit. THIRD_PARTY_NOTICES.md in the RpTv repository explains how.")
            }
        }
        .navigationTitle("Acknowledgements")
    }
}

private extension Bundle {
    var versionString: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

#Preview {
    SettingsView()
        .environment(AppModel.preview())
}
