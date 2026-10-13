// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import RpTvKit
import UserNotifications

enum ReminderError: LocalizedError {
    case notAllowed

    var errorDescription: String? {
        switch self {
        case .notAllowed: "Notifications are turned off for RpTv. Turn them on in Settings to get reminders."
        }
    }
}

/// "Remind me" for programmes: a local notification 5 minutes before the start. The pending notifications
/// are the only record of which reminders are set. Tapping one opens the channel.
@MainActor
final class Reminders: NSObject, UNUserNotificationCenterDelegate {
    static let lead: TimeInterval = 5 * 60

    /// Plays the channel with this source id and stable key. Set by the app model.
    var onOpen: ((_ sourceID: Int64, _ stableKey: String) -> Void)?

    private var center: UNUserNotificationCenter { .current() }

    override init() {
        super.init()
        // Set at launch, so a tap that launches the app still reaches `didReceive`.
        UNUserNotificationCenter.current().delegate = self
    }

    func isScheduled(_ programme: Programme, on channel: Channel) async -> Bool {
        let id = Self.identifier(programme, channel)
        return await center.pendingNotificationRequests().contains { $0.identifier == id }
    }

    /// Sets the reminder, or removes it if it's already set. Asks for permission the first time.
    /// Returns whether a reminder is now set.
    func toggle(_ programme: Programme, on channel: Channel, now: Date = .now) async throws -> Bool {
        let id = Self.identifier(programme, channel)
        if await isScheduled(programme, on: channel) {
            center.removePendingNotificationRequests(withIdentifiers: [id])
            return false
        }
        guard programme.start > now else { return false }
        try await requestPermission()

        let content = UNMutableNotificationContent()
        content.title = programme.title
        content.body = "Starts at \(programme.start.formatted(date: .omitted, time: .shortened)) on \(channel.name)."
        content.sound = .default
        content.userInfo = ["sourceID": channel.sourceID, "stableKey": channel.stableKey]
        // Already inside the last 5 minutes: remind straight away.
        let delay = max(programme.start.timeIntervalSince(now) - Self.lead, 1)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        return true
    }

    private func requestPermission() async throws {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return
        case .notDetermined:
            guard try await center.requestAuthorization(options: [.alert, .sound]) else { throw ReminderError.notAllowed }
        default:
            throw ReminderError.notAllowed
        }
    }

    private static func identifier(_ programme: Programme, _ channel: Channel) -> String {
        "reminder.\(channel.sourceID).\(channel.stableKey).\(Int64(programme.start.timeIntervalSince1970))"
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show reminders while the app is open too.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let sourceID = (info["sourceID"] as? NSNumber)?.int64Value, let stableKey = info["stableKey"] as? String else { return }
        await MainActor.run { onOpen?(sourceID, stableKey) }
    }
}
