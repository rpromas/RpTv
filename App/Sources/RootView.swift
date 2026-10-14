// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        Group {
            if !model.hasLoadedSources {
                ProgressView()
            } else if model.sources.isEmpty {
                WelcomeView()
            } else {
                MainTabView()
            }
        }
        // On Mac the sheet is a small window-centered card; soften the app behind it so it stands out.
        .blur(radius: Self.blursBehindSheets && model.isAddingSource ? 8 : 0)
        .animation(.easeInOut(duration: 0.25), value: model.isAddingSource)
        .task { await model.observeSources() }
        .task { await model.observeFavorites() }
        .task(id: model.hasLoadedSources) {
            if model.hasLoadedSources { await model.resumeLastChannelIfEnabled() }
        }
        .task(id: model.hasLoadedSources) {
            if model.hasLoadedSources { await model.refreshStaleSources() }
        }
        // Guides refresh on their own schedule, alongside the catalogs.
        .task(id: model.hasLoadedSources) {
            if model.hasLoadedSources { await model.refreshStaleGuides() }
        }
        .sheet(isPresented: $model.isAddingSource) {
            AddSourceView()
        }
        .sheet(item: $model.pinRequest) { request in
            PINUnlockView(request: request)
        }
        // Locked categories close again whenever the app leaves the screen.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.parental.lock() }
        }
        .preferredColorScheme(model.settings.appearance.colorScheme)
        .fullScreenCover(item: $model.playerSession) { session in
            // Pass the model explicitly: the cover's content doesn't reliably inherit it, and the player's
            // favorite button and channel list read it.
            PlayerScreen(session: session)
                .environment(model)
        }
        .alert("Something went wrong", isPresented: .init(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    private static let blursBehindSheets = ProcessInfo.processInfo.isiOSAppOnMac || ProcessInfo.processInfo.isMacCatalystApp
}

struct MainTabView: View {
    var body: some View {
        TabView {
            Tab("Live TV", systemImage: "tv") {
                LiveTVView()
            }
            Tab("Guide", systemImage: "list.bullet.rectangle") {
                GuideView()
            }
            Tab("Movies", systemImage: "film") {
                MoviesView()
            }
            Tab("Settings", systemImage: "gearshape") {
                SettingsView()
            }
            Tab(role: .search) {
                SearchView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}
