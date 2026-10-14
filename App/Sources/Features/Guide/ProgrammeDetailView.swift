// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import RpTvKit
import SwiftUI

/// A programme from the guide: what it is and when, with ways to watch it or be reminded.
struct ProgrammeDetailView: View {
    let channel: Channel
    let programmeID: Int64
    /// Plays the channel live, or the programme from the archive when given one.
    let onWatch: (_ catchup: Programme?) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var programme: Programme?
    @State private var hasLoaded = false
    @State private var hasReminder = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let programme {
                    TimelineView(.everyMinute) { timeline in
                        details(programme, now: timeline.date)
                    }
                } else if hasLoaded {
                    ContentUnavailableView("Programme Not Found", systemImage: "list.bullet.rectangle",
                                           description: Text("The guide has changed since it was opened."))
                } else {
                    ProgressView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            programme = try? await model.database.programme(id: programmeID)
            hasLoaded = true
            if let programme { hasReminder = await model.reminders.isScheduled(programme, on: channel) }
        }
        .alert("Can't Set Reminder", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func details(_ programme: Programme, now: Date) -> some View {
        let stop = programme.stop ?? programme.start.addingTimeInterval(3600)
        let isOnAir = programme.start <= now && now < stop
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ChannelTitle(channel: channel, subtitle: nil)
                VStack(alignment: .leading, spacing: 6) {
                    Text(programme.title)
                        .font(.title2.bold())
                    Text(Self.when(programme.start, stop))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let category = programme.category {
                        Text(category)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.fill.tertiary, in: .capsule)
                    }
                    if isOnAir, let progress = programme.progress(at: now) {
                        ProgrammeProgressBar(progress: progress)
                            .frame(maxWidth: 240)
                            .padding(.top, 4)
                    }
                }
                actions(programme, now: now, isOnAir: isOnAir)
                if let summary = programme.summary {
                    Text(summary)
                        .font(.body)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    private func actions(_ programme: Programme, now: Date, isOnAir: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if programme.start <= now && !isOnAir && channel.isCatchupPlayable(programme, now: now) {
                // A recording: watching it comes first, the live channel second.
                Button("Watch Recording", systemImage: "play.fill") { onWatch(programme) }
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("watchFromStartButton")
                Button("Watch Live", systemImage: "dot.radiowaves.left.and.right") { onWatch(nil) }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("watchChannelButton")
            } else {
                Button("Watch Channel", systemImage: "play.fill") { onWatch(nil) }
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("watchChannelButton")
                if channel.isCatchupPlayable(programme, now: now) {
                    Button("Watch from Start", systemImage: "clock.arrow.circlepath") { onWatch(programme) }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("watchFromStartButton")
                }
            }
            if programme.start > now {
                Button(hasReminder ? "Cancel Reminder" : "Remind Me", systemImage: hasReminder ? "bell.slash" : "bell") {
                    Task { await toggleReminder(programme) }
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("remindMeButton")
            }
        }
        .controlSize(.large)
    }

    private func toggleReminder(_ programme: Programme) async {
        do {
            hasReminder = try await model.reminders.toggle(programme, on: channel)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// "Tuesday 14 October, 20:00–21:30"
    private static func when(_ start: Date, _ stop: Date) -> String {
        let day = start.formatted(.dateTime.weekday(.wide).day().month(.wide))
        let time = Date.FormatStyle.dateTime.hour().minute()
        return "\(day), \(start.formatted(time))–\(stop.formatted(time))"
    }
}
