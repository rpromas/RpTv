// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Synchronization
import Testing
@testable import RpTvKit

/// Face ID that answers as told.
struct StubBiometrics: BiometricAuthenticator {
    var name: String? = "Face ID"
    var succeeds = true

    func authenticate(reason: String) async -> Bool { succeeds }
}

/// A clock tests can move forward.
final class TestClock: Sendable {
    private let date = Mutex(Date(timeIntervalSince1970: 1_000_000))

    var now: Date { date.withLock { $0 } }

    func advance(by seconds: TimeInterval) {
        date.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

@MainActor
struct ParentalControlsTests {
    let store = InMemoryCredentialStore()
    let clock = TestClock()

    private func controls(biometrics: StubBiometrics = StubBiometrics()) -> ParentalControls {
        let clock = clock
        return ParentalControls(store: store, biometrics: biometrics, now: { clock.now })
    }

    @Test func nothingIsRestrictedWithoutAPIN() throws {
        let parental = controls()
        #expect(!parental.hasPIN)
        #expect(!parental.isRestricted)
        // There's nothing to unlock.
        try parental.unlock(pin: "0000")
        #expect(!parental.isRestricted)
    }

    @Test func rejectsPINsThatArentFourDigits() {
        let parental = controls()
        for pin in ["123", "12345", "12a4", "", "１２３４", "12 4"] {
            #expect(throws: ParentalControlsError.invalidPIN) { try parental.setPIN(pin) }
        }
        #expect(!parental.hasPIN)
    }

    @Test func storesThePINAndRestrictsTheNextLaunch() throws {
        let parental = controls()
        try parental.setPIN("2468")
        #expect(try store.password(for: "parental.pin") == "2468")
        // Whoever just set it is in.
        #expect(!parental.isRestricted)

        let relaunched = controls()
        #expect(relaunched.hasPIN)
        #expect(relaunched.isRestricted)
    }

    @Test func unlocksWithTheRightPINAndLocksAgain() throws {
        try controls().setPIN("2468")
        let parental = controls()
        #expect(throws: ParentalControlsError.wrongPIN(attemptsLeft: 4)) { try parental.unlock(pin: "1111") }
        #expect(parental.isRestricted)
        try parental.unlock(pin: "2468")
        #expect(parental.isUnlocked)
        #expect(!parental.isRestricted)
        parental.lock()
        #expect(parental.isRestricted)
    }

    @Test func blocksAMinuteAfterFiveWrongPINs() throws {
        try controls().setPIN("2468")
        let parental = controls()
        for left in [4, 3, 2, 1] {
            #expect(throws: ParentalControlsError.wrongPIN(attemptsLeft: left)) { try parental.unlock(pin: "0000") }
        }
        let until = clock.now.addingTimeInterval(ParentalControls.lockoutDuration)
        #expect(throws: ParentalControlsError.tooManyAttempts(until: until)) { try parental.unlock(pin: "0000") }
        // Even the right PIN is refused while blocked.
        #expect(throws: ParentalControlsError.tooManyAttempts(until: until)) { try parental.unlock(pin: "2468") }
        #expect(parental.isRestricted)

        clock.advance(by: ParentalControls.lockoutDuration)
        try parental.unlock(pin: "2468")
        #expect(!parental.isRestricted)
    }

    @Test func aRightPINResetsTheCount() throws {
        try controls().setPIN("2468")
        let parental = controls()
        for _ in 0..<4 { _ = try? parental.unlock(pin: "0000") }
        try parental.unlock(pin: "2468")
        parental.lock()
        #expect(throws: ParentalControlsError.wrongPIN(attemptsLeft: 4)) { try parental.unlock(pin: "0000") }
    }

    @Test func changingSettingsNeedsTheSessionUnlocked() throws {
        try controls().setPIN("2468")
        let parental = controls()
        #expect(throws: ParentalControlsError.locked) { try parental.setPIN("1357") }
        #expect(throws: ParentalControlsError.locked) { try parental.setUsesBiometrics(true) }
        #expect(throws: ParentalControlsError.locked) { try parental.removePIN() }
        #expect(try store.password(for: "parental.pin") == "2468")

        try parental.unlock(pin: "2468")
        try parental.setPIN("1357")
        parental.lock()
        #expect(throws: ParentalControlsError.wrongPIN(attemptsLeft: 4)) { try parental.unlock(pin: "2468") }
        try parental.unlock(pin: "1357")
    }

    @Test func faceIDUnlocksOnlyWhenTurnedOn() async throws {
        try controls().setPIN("2468")
        let parental = controls()
        #expect(await parental.unlockWithBiometrics(reason: "Test") == false)
        #expect(parental.isRestricted)

        try parental.unlock(pin: "2468")
        try parental.setUsesBiometrics(true)
        parental.lock()
        #expect(await parental.unlockWithBiometrics(reason: "Test"))
        #expect(!parental.isRestricted)

        // A failed scan leaves it locked, and so does a device without Face ID.
        let failing = controls(biometrics: StubBiometrics(succeeds: false))
        #expect(failing.usesBiometrics)
        #expect(await failing.unlockWithBiometrics(reason: "Test") == false)
        #expect(failing.isRestricted)
        let without = controls(biometrics: StubBiometrics(name: nil))
        #expect(await without.unlockWithBiometrics(reason: "Test") == false)
    }

    @Test func removingThePINTurnsEverythingOff() throws {
        let parental = controls()
        try parental.setPIN("2468")
        try parental.setUsesBiometrics(true)
        try parental.removePIN()
        #expect(!parental.hasPIN)
        #expect(!parental.usesBiometrics)
        #expect(!parental.isRestricted)
        #expect(try store.password(for: "parental.pin") == nil)
        #expect(try store.password(for: "parental.biometrics") == nil)
        #expect(!controls().hasPIN)
    }
}
