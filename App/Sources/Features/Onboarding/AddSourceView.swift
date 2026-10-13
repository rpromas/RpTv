// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import RpTvKit
import SwiftUI
import UniformTypeIdentifiers

struct AddSourceView: View {
    enum Method: String, CaseIterable, Identifiable {
        case xtream = "Xtream Codes"
        case playlistURL = "Playlist URL"
        case playlistFile = "File"

        var id: Self { self }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var method = Method.xtream
    @State private var name = ""
    @State private var playlistURL = ""
    @State private var epgURL = ""
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var userAgent = ""
    @State private var pickedFile: URL?
    @State private var isPickingFile = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $method) {
                        ForEach(Method.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                switch method {
                case .xtream: xtreamFields
                case .playlistURL: playlistURLFields
                case .playlistFile: playlistFileFields
                }

                Section {
                    TextField("Name (optional)", text: $name)
                }

                Section("Advanced") {
                    if method != .xtream {
                        TextField("EPG URL (optional)", text: $epgURL)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    TextField("User-Agent (optional)", text: $userAgent)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .disabled(isWorking)
            .navigationTitle("Add Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .disabled(isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", role: .confirm) {
                        Task { await submit() }
                    }
                    .disabled(!canSubmit || isWorking)
                }
            }
            .overlay {
                if isWorking { SyncProgressOverlay(phase: currentPhase) }
            }
            .fileImporter(isPresented: $isPickingFile, allowedContentTypes: [.m3uPlaylist, .plainText, .data]) { result in
                if case .success(let url) = result { pickedFile = url }
            }
            .interactiveDismissDisabled(isWorking)
        }
    }

    private var xtreamFields: some View {
        Section {
            TextField("Server (http://example.com:8080)", text: $server)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Username", text: $username)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Password", text: $password)
                .textContentType(.password)
        } footer: {
            Text("Gives you live TV, movies, series and the TV guide.")
        }
    }

    private var playlistURLFields: some View {
        Section {
            TextField("http://example.com/playlist.m3u", text: $playlistURL)
                .accessibilityIdentifier("playlistURLField")
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if let detected = XtreamCredentials(playlistURL: playlistURL) {
                Button {
                    server = detected.server.absoluteString
                    username = detected.username
                    password = detected.password
                    method = .xtream
                } label: {
                    Label("This is an Xtream link. Log in with the account instead to get movies, series and the guide.",
                          systemImage: "sparkles")
                        .font(.footnote)
                }
            }
        } footer: {
            Text("An M3U or M3U8 playlist link from your provider.")
        }
    }

    private var playlistFileFields: some View {
        Section {
            Button {
                isPickingFile = true
            } label: {
                LabeledContent("Playlist file") {
                    Text(pickedFile?.lastPathComponent ?? "Choose…")
                        .foregroundStyle(pickedFile == nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
            }
            .foregroundStyle(.primary)
        } footer: {
            Text("Import an .m3u file from Files. RpTv keeps its own copy.")
        }
    }

    private var canSubmit: Bool {
        switch method {
        case .xtream: server.nonEmptyTrimmed != nil && username.nonEmptyTrimmed != nil && !password.isEmpty
        case .playlistURL: playlistURL.nonEmptyTrimmed != nil
        case .playlistFile: pickedFile != nil
        }
    }

    /// Progress of the sync this sheet started. New sources are the newest, so match on the highest id.
    private var currentPhase: SyncPhase? {
        model.syncPhases.max { $0.key < $1.key }?.value
    }

    private func submit() async {
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            switch method {
            case .xtream:
                try await model.addXtream(name: name, server: server, username: username.trimmingCharacters(in: .whitespaces),
                                          password: password, userAgent: userAgent)
            case .playlistURL:
                try await model.addPlaylist(name: name, url: playlistURL, epgURL: epgURL, userAgent: userAgent)
            case .playlistFile:
                guard let pickedFile else { return }
                try await model.addPlaylistFile(name: name, fileURL: pickedFile)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// A card showing how far a sync has got.
struct SyncProgressOverlay: View {
    let phase: SyncPhase?

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.headline)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
        .padding(28)
        .frame(minWidth: 220)
        .glassEffect(in: .rect(cornerRadius: 28))
        .animation(.default, value: phase)
    }

    private var title: String {
        switch phase {
        case nil, .connecting: "Connecting…"
        case .downloading: "Downloading…"
        case .saving: "Saving…"
        case .finished: "Done"
        }
    }

    private var detail: String? {
        switch phase {
        case .downloading(let count), .saving(let count), .finished(let count):
            count > 0 ? "\(count.formatted()) channels" : nil
        default:
            nil
        }
    }
}

#Preview {
    AddSourceView()
        .environment(AppModel.preview())
}
