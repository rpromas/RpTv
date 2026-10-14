// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import RpTvKit
import SwiftUI

/// Details of one source: its account, its categories and its TV guide. Changes go through ``EditSourceView``.
struct SourceDetailView: View {
    let sourceID: Int64
    @Environment(AppModel.self) private var model
    @State private var isEditing = false

    var body: some View {
        // Read from the model so the screen reflects saved changes and syncs.
        if let source = model.sources.first(where: { $0.id == sourceID }) {
            Form {
                Section {
                    LabeledContent("Type", value: source.kind == .xtream ? "Xtream Codes" : "M3U Playlist")
                    // Only the host: playlist URLs often carry a username and password.
                    if source.isLocalFile {
                        LabeledContent("Location", value: "Imported file")
                    } else if let host = URL(string: source.location)?.host() {
                        LabeledContent(source.kind == .xtream ? "Server" : "Host", value: host)
                    }
                    if let username = source.username {
                        LabeledContent("Username", value: username)
                    }
                    LabeledContent("Player", value: source.enginePreference == .automatic
                                   ? "Default (\(model.settings.defaultEngine.title))" : source.enginePreference.title)
                }

                if source.kind == .xtream {
                    AccountSection(source: source)
                }

                Section {
                    NavigationLink("Live TV Categories") {
                        CategoryManagerView(sourceID: sourceID, kind: .live)
                    }
                    NavigationLink("Movie Categories") {
                        CategoryManagerView(sourceID: sourceID, kind: .movie)
                    }
                } header: {
                    Text("Categories")
                } footer: {
                    Text("Hide, rename, reorder or lock categories.")
                }

                GuideSection(source: source)
            }
            .navigationTitle(source.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { isEditing = true }
                        .accessibilityIdentifier("editSourceButton")
                }
            }
            .sheet(isPresented: $isEditing) {
                EditSourceView(source: source)
            }
        } else {
            ContentUnavailableView("Source Removed", systemImage: "trash")
        }
    }
}

/// The Xtream account as the server reports it: status, expiry, connections and trial.
private struct AccountSection: View {
    let source: Source
    @Environment(AppModel.self) private var model
    @State private var account: XtreamAccount?
    @State private var error: String?

    var body: some View {
        Section {
            if let user = account?.user {
                LabeledContent("Status", value: user.status ?? "Unknown")
                LabeledContent("Expires") {
                    if let expiresAt = user.expiresAt {
                        Text(expiresAt, format: .dateTime.day().month().year())
                            .foregroundStyle(source.daysUntilExpiry() != nil ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    } else {
                        Text("Never")
                    }
                }
                if let max = user.maxConnections {
                    LabeledContent("Connections", value: "\(user.activeConnections ?? 0) of \(max)")
                }
                LabeledContent("Trial", value: user.isTrial ? "Yes" : "No")
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                HStack {
                    Text("Checking…")
                        .foregroundStyle(.secondary)
                    Spacer()
                    ProgressView()
                }
            }
        } header: {
            Text("Account")
        }
        .task(id: [source.location, source.username ?? "", source.credentialKey ?? ""]) {
            error = nil
            do {
                account = try await model.accountStatus(of: source)
            } catch is CancellationError {
            } catch {
                account = nil
                self.error = error.localizedDescription
            }
        }
    }
}

/// The source's TV guide: where it comes from, when it was last fetched, and a way to fetch it now.
private struct GuideSection: View {
    let source: Source
    @Environment(AppModel.self) private var model

    private var isSyncing: Bool { source.id.map(model.guideSyncing.contains) ?? false }

    var body: some View {
        Section {
            LabeledContent("Guide", value: source.epgURL.flatMap { URL(string: $0)?.host() }
                           ?? (source.kind == .xtream ? "From the provider" : "None"))
            LabeledContent("Last Updated") {
                status
            }
            Button {
                model.refreshGuideInBackground(source, force: true)
            } label: {
                HStack {
                    Text("Update Guide")
                    Spacer()
                    if isSyncing { ProgressView() }
                }
            }
            .disabled(isSyncing || !EPGSyncService.hasGuide(source))
        } header: {
            Text("TV Guide")
        } footer: {
            Text(source.kind == .xtream
                 ? "Programmes are matched to channels by guide ID, then by name. Set a guide URL with Edit."
                 : "Programmes are matched to channels by tvg-id, then by name. Set a guide URL with Edit.")
        }
    }

    @ViewBuilder private var status: some View {
        if isSyncing {
            Text("Updating…")
        } else if let error = source.lastEPGSyncError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(3)
        } else if let date = source.lastEPGSyncAt {
            Text(date, format: .relative(presentation: .named))
        } else {
            Text("Never")
        }
    }
}

#Preview {
    NavigationStack {
        SourceDetailView(sourceID: 1)
    }
    .environment(AppModel.preview())
}
