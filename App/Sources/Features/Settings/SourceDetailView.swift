// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import RpTvKit
import SwiftUI

/// Details and per-source options of one source.
struct SourceDetailView: View {
    let sourceID: Int64
    @Environment(AppModel.self) private var model

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
                }

                GuideSection(source: source)

                Section {
                    Picker("Player Engine", selection: enginePreference(of: source)) {
                        ForEach(EnginePreference.allCases, id: \.self) { preference in
                            Text(preference.title).tag(preference)
                        }
                    }
                } footer: {
                    Text(source.enginePreference.explanation)
                }
            }
            .navigationTitle(source.name)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Source Removed", systemImage: "trash")
        }
    }

    private func enginePreference(of source: Source) -> Binding<EnginePreference> {
        Binding {
            source.enginePreference
        } set: { preference in
            Task { await model.setEnginePreference(preference, for: source) }
        }
    }
}

/// The source's TV guide: where it comes from, when it was last fetched, and a way to fetch it now.
private struct GuideSection: View {
    let source: Source
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @FocusState private var isEditing: Bool

    private var isSyncing: Bool { source.id.map(model.guideSyncing.contains) ?? false }

    var body: some View {
        Section {
            TextField("Guide URL", text: $draft,
                      prompt: Text(source.kind == .xtream ? "Provided by the server" : "XMLTV URL").foregroundStyle(.secondary))
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($isEditing)
                .onSubmit(save)
                .onChange(of: isEditing) { _, editing in
                    if !editing { save() }
                }
                .accessibilityLabel("Guide URL")
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
                 ? "Leave empty to use your provider's guide. Programmes are matched to channels by guide ID, then by name, and refresh every 12 hours."
                 : "An XMLTV file, optionally gzipped. Programmes are matched to channels by tvg-id, then by name, and refresh every 12 hours.")
        }
        .task(id: source.epgURL) { draft = source.epgURL ?? "" }
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

    private func save() {
        Task { await model.setEPGURL(draft, for: source) }
    }
}

private extension EnginePreference {
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .native: "Native"
        case .vlc: "VLC"
        }
    }

    var explanation: String {
        switch self {
        case .automatic:
            "Picks a player for each stream, and switches to VLC when the native player can't play it."
        case .native:
            "Always uses the native player, which supports Picture in Picture and AirPlay but not every stream format."
        case .vlc:
            "Always uses VLC, which plays almost any stream format but doesn't support Picture in Picture or AirPlay yet."
        }
    }
}

#Preview {
    NavigationStack {
        SourceDetailView(sourceID: 1)
    }
    .environment(AppModel.preview())
}
