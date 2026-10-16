// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import LocalAuthentication
import Observation

public enum ParentalControlsError: LocalizedError, Equatable {
    case invalidPIN
    case wrongPIN(attemptsLeft: Int)
    case tooManyAttempts(until: Date)
    /// The change needs the PIN entered first.
    case locked

    public var errorDescription: String? {
        switch self {
        case .invalidPIN: "The PIN must be \(ParentalControls.pinLength) digits."
        case .wrongPIN(let left): left == 1 ? "Wrong PIN. 1 attempt left." : "Wrong PIN. \(left) attempts left."
        case .tooManyAttempts: "Too many wrong attempts. Try again in a minute."
        case .locked: "Enter the parental PIN first."
        }
    }
}

/// Confirms the device owner with Face ID or Touch ID.
public protocol BiometricAuthenticator: Sendable {
    /// "Face ID", "Touch ID", or `nil` when the device has neither set up.
    var name: String? { get }
    func authenticate(reason: String) async -> Bool
}

/// ``BiometricAuthenticator`` backed by `LocalAuthentication`.
public struct DeviceBiometrics: BiometricAuthenticator {
    public init() {}

    public var name: String? {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        return switch context.biometryType {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .opticID: "Optic ID"
        default: nil
        }
    }

    public func authenticate(reason: String) async -> Bool {
        (try? await LAContext().evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)) ?? false
    }
}

/// The parental-control PIN, and whether locked categories are open in this session.
///
/// Without a PIN nothing is restricted. With one, locked content stays hidden between ``lock()`` and a
/// successful ``unlock(pin:)`` or Face ID. After ``maxAttempts`` wrong PINs, unlocking is refused for
/// ``lockoutDuration``.
@MainActor
@Observable
public final class ParentalControls {
    public nonisolated static let pinLength = 4
    public nonisolated static let maxAttempts = 5
    public nonisolated static let lockoutDuration: TimeInterval = 60

    public private(set) var hasPIN: Bool
    public private(set) var isUnlocked = false
    /// Whether Face ID or Touch ID can stand in for the PIN.
    public private(set) var usesBiometrics: Bool

    /// Whether locked content has to stay hidden right now.
    public var isRestricted: Bool { hasPIN && !isUnlocked }

    @ObservationIgnored private let store: any CredentialStore
    @ObservationIgnored public let biometrics: any BiometricAuthenticator
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var failedAttempts = 0
    @ObservationIgnored private var blockedUntil: Date?

    private static let pinKey = "parental.pin"
    private static let biometricsKey = "parental.biometrics"

    public init(store: any CredentialStore, biometrics: any BiometricAuthenticator = DeviceBiometrics(),
                now: @escaping @Sendable () -> Date = { .now }) {
        self.store = store
        self.biometrics = biometrics
        self.now = now
        hasPIN = (try? store.password(for: Self.pinKey)) != nil
        usesBiometrics = (try? store.password(for: Self.biometricsKey)) == "1"
    }

    /// Whether `pin` has the right shape: exactly ``pinLength`` ASCII digits.
    public nonisolated static func isValid(_ pin: String) -> Bool {
        pin.count == pinLength && pin.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Sets a new PIN, or changes it. Changing it needs the session unlocked. Leaves the session unlocked.
    public func setPIN(_ pin: String) throws {
        guard !hasPIN || isUnlocked else { throw ParentalControlsError.locked }
        guard Self.isValid(pin) else { throw ParentalControlsError.invalidPIN }
        try store.setPassword(pin, for: Self.pinKey)
        hasPIN = true
        isUnlocked = true
    }

    /// Opens locked content for the session when `pin` is right.
    public func unlock(pin: String) throws {
        guard hasPIN else { return }
        if let blockedUntil, now() < blockedUntil { throw ParentalControlsError.tooManyAttempts(until: blockedUntil) }
        blockedUntil = nil
        guard pin == (try store.password(for: Self.pinKey)) else {
            failedAttempts += 1
            if failedAttempts >= Self.maxAttempts {
                failedAttempts = 0
                let until = now().addingTimeInterval(Self.lockoutDuration)
                blockedUntil = until
                throw ParentalControlsError.tooManyAttempts(until: until)
            }
            throw ParentalControlsError.wrongPIN(attemptsLeft: Self.maxAttempts - failedAttempts)
        }
        failedAttempts = 0
        isUnlocked = true
    }

    /// Opens locked content with Face ID or Touch ID, if the user turned that on. Returns whether it worked.
    public func unlockWithBiometrics(reason: String) async -> Bool {
        guard hasPIN, usesBiometrics, biometrics.name != nil else { return false }
        guard await biometrics.authenticate(reason: reason) else { return false }
        failedAttempts = 0
        blockedUntil = nil
        isUnlocked = true
        return true
    }

    /// Hides locked content again.
    public func lock() {
        isUnlocked = false
    }

    public func setUsesBiometrics(_ uses: Bool) throws {
        guard hasPIN, isUnlocked else { throw ParentalControlsError.locked }
        if uses {
            try store.setPassword("1", for: Self.biometricsKey)
        } else {
            try store.deletePassword(for: Self.biometricsKey)
        }
        usesBiometrics = uses
    }

    /// Turns parental controls off. Needs the session unlocked.
    public func removePIN() throws {
        guard hasPIN else { return }
        guard isUnlocked else { throw ParentalControlsError.locked }
        try store.deletePassword(for: Self.pinKey)
        try store.deletePassword(for: Self.biometricsKey)
        hasPIN = false
        usesBiometrics = false
        isUnlocked = false
    }
}
