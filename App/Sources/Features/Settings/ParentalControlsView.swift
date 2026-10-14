// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import RpTvKit
import SwiftUI

/// The parental PIN and Face ID. Settings opens it only after the PIN is entered.
struct ParentalControlsView: View {
    @Environment(AppModel.self) private var model
    @State private var isSettingPIN = false
    @State private var isConfirmingTurnOff = false

    var body: some View {
        let parental = model.parental
        Form {
            if parental.hasPIN {
                Section {
                    if let biometrics = parental.biometrics.name {
                        Toggle("Unlock with \(biometrics)", isOn: Binding(
                            get: { parental.usesBiometrics },
                            set: { uses in
                                do {
                                    try parental.setUsesBiometrics(uses)
                                } catch {
                                    model.alertMessage = error.localizedDescription
                                }
                            }))
                    }
                    Button("Change PIN") { isSettingPIN = true }
                    if parental.isUnlocked {
                        Button("Lock Now") { parental.lock() }
                    }
                } footer: {
                    Text("Lock categories in each source's Categories screen. Locked categories ask for the PIN, and their channels and movies stay out of lists, search, favorites and recents until it's entered. They lock again when RpTv goes to the background.")
                }

                Section {
                    Button("Turn Off Parental Controls", role: .destructive) { isConfirmingTurnOff = true }
                        .disabled(!parental.isUnlocked)
                }
            } else {
                Section {
                    Button("Set PIN") { isSettingPIN = true }
                        .accessibilityIdentifier("setPINButton")
                } footer: {
                    Text("Choose a \(ParentalControls.pinLength)-digit PIN, then lock categories in each source's Categories screen. Locked categories ask for the PIN before showing what's in them.")
                }
            }
        }
        .navigationTitle("Parental Controls")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isSettingPIN) {
            PINCreateView {}
        }
        .confirmationDialog("Turn off parental controls?", isPresented: $isConfirmingTurnOff, titleVisibility: .visible) {
            Button("Turn Off", role: .destructive) {
                Task { await model.turnOffParentalControls() }
            }
        } message: {
            Text("The PIN is removed and every category is unlocked.")
        }
    }
}

#Preview {
    NavigationStack {
        ParentalControlsView()
    }
    .environment(AppModel.preview())
}
