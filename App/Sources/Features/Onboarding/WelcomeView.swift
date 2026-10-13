// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// First-run screen. The app ships without content, so the only way forward is adding a source.
struct WelcomeView: View {
    @State private var isAddingSource = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "play.tv.fill")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
                .symbolEffect(.breathe)
            VStack(spacing: 12) {
                Text("Welcome to RpTv")
                    .font(.largeTitle.bold())
                Text("Add your IPTV playlist or Xtream Codes account to start watching.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            VStack(spacing: 16) {
                Button {
                    isAddingSource = true
                } label: {
                    Text("Add Source")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)

                Text("RpTv is a player only and doesn't provide any channels or content.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: 520)
        .sheet(isPresented: $isAddingSource) {
            AddSourceView()
        }
    }
}

#Preview {
    WelcomeView()
        .environment(AppModel.preview())
}
