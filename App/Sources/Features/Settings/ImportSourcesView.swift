// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import RpTvKit
import SwiftUI

/// Adds the sources of an export file, asking for each Xtream account's password, since exports don't carry them.
struct ImportSourcesView: View {
    let export: SourceExport

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var passwords: [Int: String] = [:]
    @State private var outcomes: [Int: Outcome] = [:]
    @State private var isWorking = false

    private enum Outcome {
        case importing
        case added
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(Array(export.sources.enumerated()), id: \.offset) { index, entry in
                        row(entry, index: index)
                    }
                } footer: {
                    Text("Exports don't include passwords. Enter each account's password to add it, or leave it empty to skip it.")
                }
            }
            .navigationTitle("Import Sources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isDone ? "Done" : "Cancel", role: .cancel) { dismiss() }
                        .disabled(isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import", role: .confirm) {
                        Task { await importAll() }
                    }
                    .disabled(isWorking || pending.isEmpty)
                }
            }
            .interactiveDismissDisabled(isWorking)
        }
    }

    private func row(_ entry: SourceExport.Entry, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.body.weight(.medium))
                    Text("\(entry.kind == .xtream ? "Xtream Codes" : "M3U Playlist") · \(URL(string: entry.location)?.host() ?? entry.location)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                status(entry, index: index)
            }
            if entry.needsPassword, isPending(entry, index: index) {
                SecureField("Password for \(entry.username ?? "the account")", text: Binding(
                    get: { passwords[index, default: ""] },
                    set: { passwords[index] = $0 }))
                    .textContentType(.password)
                    .disabled(isWorking)
            }
            if case .failed(let message) = outcomes[index] {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func status(_ entry: SourceExport.Entry, index: Int) -> some View {
        switch outcomes[index] {
        case .importing:
            ProgressView()
        case .added:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Added")
        case .failed, nil:
            if model.hasSource(like: entry) {
                Text("Already added")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func isPending(_ entry: SourceExport.Entry, index: Int) -> Bool {
        switch outcomes[index] {
        case .added, .importing: false
        case .failed, nil: !model.hasSource(like: entry)
        }
    }

    /// The sources left to import: not added yet, and with a password when they need one.
    private var pending: [Int] {
        export.sources.indices.filter { index in
            let entry = export.sources[index]
            return isPending(entry, index: index) && (!entry.needsPassword || !passwords[index, default: ""].isEmpty)
        }
    }

    private var isDone: Bool {
        outcomes.values.contains { if case .added = $0 { true } else { false } }
    }

    private func importAll() async {
        isWorking = true
        defer { isWorking = false }
        for index in pending {
            outcomes[index] = .importing
            do {
                try await model.importSource(export.sources[index], password: passwords[index, default: ""])
                outcomes[index] = .added
            } catch {
                outcomes[index] = .failed(error.localizedDescription)
            }
        }
        if pending.isEmpty, !outcomes.values.contains(where: { if case .failed = $0 { true } else { false } }) {
            dismiss()
        }
    }
}

#Preview {
    ImportSourcesView(export: SourceExport(sources: [
        Source(name: "Home", kind: .xtream, location: "http://example.com:8080", username: "demo"),
        Source(name: "Playlist", kind: .m3u, location: "http://example.com/list.m3u"),
    ]))
    .environment(AppModel.preview())
}
