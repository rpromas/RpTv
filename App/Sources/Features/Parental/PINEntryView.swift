// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import RpTvKit
import SwiftUI

/// Asks for the parental PIN, or Face ID when the user turned it on, and answers a ``PINRequest``.
struct PINUnlockView: View {
    let request: PINRequest

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            PINPad(title: "Enter PIN", subtitle: request.reason, message: message, attempt: attempt,
                   biometricsName: biometricsName, onBiometrics: useBiometrics) { pin in
                do {
                    try model.parental.unlock(pin: pin)
                    finish(true)
                } catch {
                    message = error.localizedDescription
                    attempt += 1
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { finish(false) }
                }
            }
        }
        .task {
            if biometricsName != nil { useBiometrics() }
        }
        // Swiping the sheet away counts as cancelling.
        .onDisappear { request.finish(false) }
    }

    private var biometricsName: String? {
        model.parental.usesBiometrics ? model.parental.biometrics.name : nil
    }

    private func useBiometrics() {
        Task {
            if await model.parental.unlockWithBiometrics(reason: request.reason) { finish(true) }
        }
    }

    private func finish(_ granted: Bool) {
        request.finish(granted)
        dismiss()
    }
}

/// Sets a new PIN: once, then again to confirm.
struct PINCreateView: View {
    let onDone: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var first: String?
    @State private var message: String?
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            PINPad(title: first == nil ? "Choose a PIN" : "Confirm PIN",
                   subtitle: first == nil ? "Enter \(ParentalControls.pinLength) digits." : "Enter the same PIN again.",
                   message: message, attempt: attempt) { pin in
                guard let first else {
                    self.first = pin
                    message = nil
                    return
                }
                guard pin == first else {
                    self.first = nil
                    message = "The PINs didn't match. Try again."
                    attempt += 1
                    return
                }
                do {
                    try model.parental.setPIN(pin)
                    onDone()
                    dismiss()
                } catch {
                    self.first = nil
                    message = error.localizedDescription
                    attempt += 1
                }
            }
            .id(first == nil)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
        }
    }
}

/// Four dots and a number pad. Hardware keyboards can type the digits too.
private struct PINPad: View {
    let title: String
    let subtitle: String
    var message: String?
    /// Goes up on every wrong entry, which clears the dots and shakes them.
    var attempt = 0
    var biometricsName: String?
    var onBiometrics: () -> Void = {}
    let onComplete: (String) -> Void

    @State private var digits = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 18) {
                ForEach(0..<ParentalControls.pinLength, id: \.self) { index in
                    Circle()
                        .fill(index < digits.count ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                        .frame(width: 14, height: 14)
                }
            }
            .keyframeAnimator(initialValue: 0.0, trigger: attempt) { content, offset in
                content.offset(x: offset)
            } keyframes: { _ in
                KeyframeTrack {
                    for offset in [-12.0, 10, -8, 6, -3, 0] { LinearKeyframe(offset, duration: 0.06) }
                }
            }
            .accessibilityElement()
            .accessibilityLabel("\(digits.count) of \(ParentalControls.pinLength) digits entered")

            Text(message ?? " ")
                .font(.footnote)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .frame(minHeight: 36, alignment: .top)

            Grid(horizontalSpacing: 22, verticalSpacing: 16) {
                ForEach([["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]], id: \.self) { row in
                    GridRow {
                        ForEach(row, id: \.self) { digit in key(digit) }
                    }
                }
                GridRow {
                    if let biometricsName {
                        Button(biometricsName, systemImage: biometricsName == "Touch ID" ? "touchid" : "faceid", action: onBiometrics)
                            .labelStyle(.iconOnly)
                            .font(.title)
                            .frame(width: 72, height: 72)
                    } else {
                        Color.clear.frame(width: 72, height: 72)
                    }
                    key("0")
                    Button("Delete", systemImage: "delete.backward", action: deleteDigit)
                        .labelStyle(.iconOnly)
                        .font(.title2)
                        .frame(width: 72, height: 72)
                        .disabled(digits.isEmpty)
                }
            }
            .buttonStyle(.plain)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(characters: .decimalDigits) { press in
            press.characters.forEach { add($0) }
            return .handled
        }
        .onKeyPress(.delete) {
            deleteDigit()
            return .handled
        }
        .onChange(of: attempt) { digits = "" }
    }

    private func key(_ digit: String) -> some View {
        Button {
            add(Character(digit))
        } label: {
            Text(digit)
                .font(.title.weight(.medium))
                .frame(width: 72, height: 72)
                .glassEffect(.regular.interactive(), in: .circle)
        }
    }

    private func add(_ digit: Character) {
        guard digit.isASCII, digit.isNumber, digits.count < ParentalControls.pinLength else { return }
        digits.append(digit)
        if digits.count == ParentalControls.pinLength {
            let pin = digits
            // Let the last dot fill before reacting.
            Task {
                try? await Task.sleep(for: .milliseconds(120))
                digits = ""
                onComplete(pin)
            }
        }
    }

    private func deleteDigit() {
        if !digits.isEmpty { digits.removeLast() }
    }
}

/// Stands in for a locked category's contents until the PIN is entered.
struct LockedContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Locked", systemImage: "lock.fill")
        } description: {
            Text("This category is locked by parental controls.")
        } actions: {
            Button("Unlock") {
                Task { await model.unlockLockedContent() }
            }
            .buttonStyle(.glassProminent)
            .accessibilityIdentifier("unlockCategoryButton")
        }
    }
}

#Preview {
    PINCreateView {}
        .environment(AppModel.preview())
}
