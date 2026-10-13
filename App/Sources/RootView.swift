// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

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
        .task { await model.observeSources() }
        .task(id: model.hasLoadedSources) {
            if model.hasLoadedSources { await model.refreshStaleSources() }
        }
        // Guides refresh on their own schedule, alongside the catalogs.
        .task(id: model.hasLoadedSources) {
            if model.hasLoadedSources { await model.refreshStaleGuides() }
        }
        .fullScreenCover(item: $model.playerSession) { session in
            PlayerScreen(session: session)
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
}

struct MainTabView: View {
    var body: some View {
        TabView {
            Tab("Live TV", systemImage: "tv") {
                LiveTVView()
            }
            Tab("Settings", systemImage: "gearshape") {
                SettingsView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}
