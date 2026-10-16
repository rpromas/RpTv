// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import RpTvKit
import SwiftUI

/// Edits a source's name, address, login, guide, headers and player.
struct EditSourceView: View {
    let source: Source

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var edit: SourceEdit
    @State private var isWorking = false
    @State private var errorMessage: String?

    init(source: Source) {
        self.source = source
        _edit = State(initialValue: SourceEdit(source))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $edit.name, prompt: placeholder(source.name))
                }

                connectionFields

                Section {
                    TextField("Guide URL", text: $edit.epgURL,
                              prompt: placeholder(source.kind == .xtream ? "Provided by the server" : "XMLTV URL (optional)"))
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("TV Guide")
                } footer: {
                    Text(source.kind == .xtream
                         ? "Leave empty to use your provider's guide."
                         : "An XMLTV file, optionally gzipped.")
                }

                Section("Advanced") {
                    TextField("User-Agent", text: $edit.userAgent, prompt: placeholder("User-Agent (optional)"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Referer", text: $edit.referrer, prompt: placeholder("Referer (optional)"))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Picker("Player", selection: $edit.enginePreference) {
                        Text("Default (\(model.settings.defaultEngine.title))").tag(EnginePreference.automatic)
                        Text(EnginePreference.native.title).tag(EnginePreference.native)
                        Text(EnginePreference.ffmpeg.title).tag(EnginePreference.ffmpeg)
                    }
                } footer: {
                    Text(edit.enginePreference == .automatic
                         ? "Uses the default player from Settings."
                         : edit.enginePreference.explanation)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .disabled(isWorking)
            .navigationTitle("Edit Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .disabled(isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", role: .confirm) {
                        Task { await save() }
                    }
                    .disabled(!canSave || isWorking)
                }
            }
            .overlay {
                if isWorking { SyncProgressOverlay(phase: source.id.flatMap { model.syncPhases[$0] }) }
            }
            .interactiveDismissDisabled(isWorking)
        }
    }

    @ViewBuilder private var connectionFields: some View {
        switch source.kind {
        case .xtream:
            Section {
                TextField("Server", text: $edit.location, prompt: placeholder("Server (http://example.com:8080)"))
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Username", text: $edit.username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $edit.password, prompt: placeholder("Password (unchanged)"))
                    .textContentType(.password)
            } header: {
                Text("Account")
            } footer: {
                Text("Leave the password empty to keep the saved one.")
            }
        case .m3u where source.isLocalFile:
            Section("Playlist") {
                LabeledContent("Location", value: "Imported file")
            }
        case .m3u:
            Section("Playlist") {
                TextField("Playlist URL", text: $edit.location, prompt: placeholder("http://example.com/playlist.m3u"))
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
    }

    private var canSave: Bool {
        switch source.kind {
        case .xtream: edit.location.nonEmptyTrimmed != nil && edit.username.nonEmptyTrimmed != nil
        case .m3u: source.isLocalFile || edit.location.nonEmptyTrimmed != nil
        }
    }

    /// Placeholder text, kept gray so it never reads as an entered value.
    private func placeholder(_ text: String) -> Text {
        Text(text).foregroundStyle(.secondary)
    }

    private func save() async {
        guard let id = source.id else { return }
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await model.save(edit, to: id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension EnginePreference {
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .native: "Native"
        case .ffmpeg: "FFmpeg"
        }
    }

    var explanation: String {
        switch self {
        case .automatic:
            "Automatic picks a player for each stream, and switches to FFmpeg when the native player can't play it."
        case .native:
            "The native player supports Picture in Picture and AirPlay but not every stream format."
        case .ffmpeg:
            "FFmpeg plays almost any stream format. Over AirPlay it only sends sound."
        }
    }
}

#Preview {
    EditSourceView(source: Source(name: "Demo", kind: .xtream, location: "http://example.com:8080", username: "demo"))
        .environment(AppModel.preview())
}
