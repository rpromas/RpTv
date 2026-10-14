// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Nuke
import RpTvKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var sourcePendingDeletion: Source?
    @State private var detailSourceID: Int64?
    @State private var showsParentalControls = false
    @State private var isConfirmingClearGuides = false
    @State private var exportDocument: SourcesDocument?
    @State private var isImporting = false
    @State private var importedSources: ImportedSources?
    @State private var storageMessage: String?
    @AppStorage(AppModel.resumeLastChannelKey) private var resumesLastChannel = false

    var body: some View {
        @Bindable var settings = model.settings
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
                        model.isAddingSource = true
                    }
                    Menu {
                        Button("Export Sources…", systemImage: "square.and.arrow.up") { export() }
                            .disabled(model.sources.allSatisfy(\.isLocalFile))
                        Button("Import Sources…", systemImage: "square.and.arrow.down") { isImporting = true }
                    } label: {
                        Label("Export or Import", systemImage: "arrow.up.arrow.down.square")
                    }
                }

                Section {
                    Picker("Default Player", selection: $settings.defaultEngine) {
                        ForEach(EnginePreference.allCases, id: \.self) { preference in
                            Text(preference.title).tag(preference)
                        }
                    }
                    Picker("Live Buffer", selection: $settings.liveBufferSeconds) {
                        Text("Automatic").tag(0)
                        ForEach([1, 2, 3, 5, 10, 20], id: \.self) { seconds in
                            Text(Duration.seconds(seconds), format: .units(allowed: [.seconds], width: .abbreviated)).tag(seconds)
                        }
                    }
                    Picker("Audio Language", selection: $settings.audioLanguage) {
                        Text("Stream Default").tag(String?.none)
                        ForEach(Language.all) { language in
                            Text(language.name).tag(Optional(language.code))
                        }
                    }
                    .pickerStyle(.navigationLink)
                    Picker("Subtitles", selection: $settings.subtitleLanguage) {
                        Text("Off").tag(String?.none)
                        ForEach(Language.all) { language in
                            Text(language.name).tag(Optional(language.code))
                        }
                    }
                    .pickerStyle(.navigationLink)
                    Toggle("Resume Last Channel", isOn: $resumesLastChannel)
                } header: {
                    Text("Playback")
                } footer: {
                    Text("\(settings.defaultEngine.explanation) Sources set to their own player keep it. Audio and subtitles in your languages are picked when a stream has them. Resume Last Channel plays the channel you watched last when RpTv opens.")
                }

                Section {
                    Picker("Channels and Movies", selection: $settings.catalogRefreshHours) {
                        Text("Every 6 Hours").tag(6)
                        Text("Every 12 Hours").tag(12)
                        Text("Daily").tag(24)
                        Text("Every 3 Days").tag(72)
                        Text("Weekly").tag(168)
                        Text("Manually").tag(0)
                    }
                    Picker("TV Guide", selection: $settings.guideRefreshHours) {
                        Text("Every 6 Hours").tag(6)
                        Text("Every 12 Hours").tag(12)
                        Text("Daily").tag(24)
                        Text("Every 3 Days").tag(72)
                    }
                } header: {
                    Text("Refresh")
                } footer: {
                    Text("How often sources refresh when RpTv opens. You can always pull down on a list to refresh it.")
                }

                Section("Appearance") {
                    Picker("Appearance", selection: $settings.appearance) {
                        Text("System").tag(AppSettings.Appearance.system)
                        Text("Light").tag(AppSettings.Appearance.light)
                        Text("Dark").tag(AppSettings.Appearance.dark)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                Section {
                    Button {
                        Task {
                            if await model.authorize(reason: "Enter your PIN to change parental controls.") {
                                showsParentalControls = true
                            }
                        }
                    } label: {
                        LabeledContent {
                            Text(model.parental.hasPIN ? "On" : "Off")
                            Image(systemName: "chevron.forward")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        } label: {
                            Label("Parental Controls", systemImage: "lock.shield")
                        }
                    }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("parentalControlsButton")
                }

                Section {
                    Button("Clear Image Cache", systemImage: "photo.stack") { clearImageCache() }
                    Button("Clear TV Guide Data", systemImage: "calendar.badge.minus", role: .destructive) {
                        isConfirmingClearGuides = true
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    Text(storageMessage ?? "Logos and posters download again when they're shown. Guides download again on the next refresh.")
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.versionString)
                    NavigationLink("Acknowledgements") { AcknowledgementsView() }
                    Link("Source Code", destination: URL(string: "https://github.com/rpromas/RpTv")!)
                    Link("Privacy Policy", destination: URL(string: "https://github.com/rpromas/RpTv/blob/main/docs/privacy.md")!)
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
            .navigationDestination(isPresented: $showsParentalControls) {
                ParentalControlsView()
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
            .confirmationDialog("Clear TV guide data?", isPresented: $isConfirmingClearGuides, titleVisibility: .visible) {
                Button("Clear", role: .destructive) {
                    Task {
                        await model.clearGuides()
                        storageMessage = "TV guide data cleared."
                    }
                }
            } message: {
                Text("Programmes of every source are removed until their guides download again.")
            }
            .fileExporter(isPresented: .init(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
                          document: exportDocument, contentType: .json, defaultFilename: "RpTv Sources") { result in
                if case .failure(let error) = result { model.alertMessage = error.localizedDescription }
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url): readImport(url)
                case .failure(let error): model.alertMessage = error.localizedDescription
                }
            }
            .sheet(item: $importedSources) { imported in
                ImportSourcesView(export: imported.export)
            }
        }
    }

    private func refresh(_ source: Source) {
        Task {
            do {
                try await model.sync(source)
                model.refreshGuideInBackground(source, force: true)
            } catch {
                model.alertMessage = error.localizedDescription
            }
        }
    }

    private func export() {
        do {
            exportDocument = SourcesDocument(data: try model.exportSources())
        } catch {
            model.alertMessage = error.localizedDescription
        }
    }

    private func readImport(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            importedSources = ImportedSources(export: try SourceExport.decode(Data(contentsOf: url)))
        } catch {
            model.alertMessage = error.localizedDescription
        }
    }

    private func clearImageCache() {
        ImagePipeline.shared.cache.removeAll()
        DataLoader.sharedUrlCache.removeAllCachedResponses()
        storageMessage = "Image cache cleared."
    }

    private struct ImportedSources: Identifiable {
        let id = UUID()
        let export: SourceExport
    }
}

/// Exported sources, for the file exporter.
private struct SourcesDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// A language the user can pick for audio or subtitles.
struct Language: Identifiable {
    let code: String
    let name: String

    var id: String { code }

    /// Every language with a two-letter code, by name in the user's language.
    static let all: [Language] = Locale.LanguageCode.isoLanguageCodes
        .map(\.identifier)
        .filter { $0.count == 2 }
        .compactMap { code in Locale.current.localizedString(forLanguageCode: code).map { Language(code: code, name: $0) } }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
                if let days = source.daysUntilExpiry() {
                    Label(Self.expiryText(days), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
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

    static func expiryText(_ days: Int) -> String {
        switch days {
        case ..<0: "The account has expired"
        case 0: "The account expires today"
        case 1: "The account expires tomorrow"
        default: "The account expires in \(days) days"
        }
    }
}

private struct AcknowledgementsView: View {
    private let libraries: [(name: String, license: String, url: String)] = [
        ("GRDB.swift", "MIT License", "https://github.com/groue/GRDB.swift"),
        ("Nuke", "MIT License", "https://github.com/kean/Nuke"),
        ("FFmpeg", "LGPL 2.1", "https://ffmpeg.org"),
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
                Text("FFmpeg is linked dynamically. You can rebuild RpTv from its source code with a modified version of FFmpeg. [THIRD_PARTY_NOTICES.md](https://github.com/rpromas/RpTv/blob/main/THIRD_PARTY_NOTICES.md) in the RpTv repository explains how.")
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
