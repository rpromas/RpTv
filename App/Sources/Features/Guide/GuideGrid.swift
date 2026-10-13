// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import RpTvKit
import SwiftUI

/// Sizes of the guide grid for one width class.
struct GuideMetrics: Equatable {
    var channelWidth: CGFloat
    var rowHeight: CGFloat
    var rulerHeight: CGFloat = 32
    var pointsPerMinute: Double
    /// Whether the channel column shows names next to the logos.
    var showsNames: Bool

    /// iPhone portrait: logos only, about an hour and a half across.
    static let compact = GuideMetrics(channelWidth: 76, rowHeight: 60, pointsPerMinute: 3.5, showsNames: false)
    /// iPad and wide windows: names too, about three hours across.
    static let regular = GuideMetrics(channelWidth: 210, rowHeight: 64, pointsPerMinute: 5, showsNames: true)
}

/// Channels down, time across, in one scroll view so every row shares the horizontal offset. The channel column
/// stays pinned on the left and the time ruler at the top. The timeline spans all of the stored guide, but
/// programmes load only for a window around what's on screen (see `GuideTimeScale.loadWindow`).
struct GuideGrid: View {
    let sourceID: Int64
    let channels: [Channel]
    let context: ChannelListContext

    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The times the stored guide covers.
    @State private var range: DateInterval?
    /// When the grid opened. Fixes the timeline's edges while the guide is empty, so it doesn't shift as time passes.
    @State private var openedAt = Date.now
    @State private var slots: [String: [GuideSlot]] = [:]
    /// The load-window bucket the viewport's left edge is in. Changes only every few hours of scrolling.
    @State private var bucket: Int?
    @State private var position = ScrollPosition()
    @State private var viewportWidth: CGFloat = 0
    @State private var hasScrolledToNow = false
    /// The exact scroll offset, kept out of SwiftUI's sight so scrolling doesn't update the view.
    @State private var offset = OffsetBox()
    @State private var selection: Selection?
    /// What to play once the detail sheet has gone.
    @State private var pendingPlay: (channel: Channel, catchup: Programme?)?

    private var metrics: GuideMetrics { sizeClass == .regular ? .regular : .compact }

    private var guideIDs: Set<String> { Set(channels.compactMap(\.guideID)) }

    private var scale: GuideTimeScale {
        let start = min(range?.start ?? openedAt, openedAt.addingTimeInterval(-3600))
        let end = max(range?.end ?? openedAt, openedAt.addingTimeInterval(3 * 3600))
        return GuideTimeScale(start: start, end: end, pointsPerMinute: metrics.pointsPerMinute)
    }

    private var currentBucket: Int { bucket ?? scale.bucket(forScrollX: scale.x(for: openedAt)) }

    var body: some View {
        let scale = scale
        let metrics = metrics
        let window = GuideTimeScale.loadWindow(bucket: currentBucket)
        TimelineView(.everyMinute) { timeline in
            let now = timeline.date
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                    Section {
                        ForEach(channels) { channel in
                            GuideRow(channel: channel, slots: channel.guideID.flatMap { slots[$0] } ?? [],
                                     scale: scale, metrics: metrics, now: now,
                                     onPlay: { play(channel) },
                                     onSelect: { slot in selection = Selection(channel: channel, programmeID: slot.id) })
                                .equatable()
                        }
                    } header: {
                        GuideRuler(scale: scale, window: window, metrics: metrics, now: now)
                    }
                }
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGPoint.self, of: { $0.contentOffset }) { _, point in
                offset.point = point
                let newBucket = scale.bucket(forScrollX: point.x)
                if newBucket != bucket { bucket = newBucket }
            }
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.containerSize.width }) { _, width in
                viewportWidth = width
                if !hasScrolledToNow, width > 0 {
                    hasScrolledToNow = true
                    scrollToNow(animated: false)
                }
            }
        }
        // When the timeline's left edge moves (a guide refresh, or the size class), keep the same time in view.
        .onChange(of: scale) { old, new in
            guard hasScrolledToNow else { return }
            scroll(toX: new.x(for: old.date(atX: offset.point.x)))
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Now", systemImage: "clock") { scrollToNow(animated: true) }
                    .labelStyle(.titleOnly)
                    .accessibilityIdentifier("guideNowButton")
            }
        }
        .task(id: RangeQuery(sourceID: sourceID, guideIDs: guideIDs)) {
            do {
                for try await range in model.database.observeGuideRange(sourceID: sourceID, guideIDs: guideIDs) {
                    self.range = range
                }
            } catch {}
        }
        .task(id: SlotQuery(sourceID: sourceID, guideIDs: guideIDs, window: window)) {
            // The guide is optional: on failure rows simply stay empty. The old slots stay up until new ones
            // arrive, so cells don't blink while scrolling.
            do {
                for try await slots in model.database.observeGuide(sourceID: sourceID, guideIDs: guideIDs, window: window) {
                    self.slots = slots
                }
            } catch {}
        }
        .sheet(item: $selection, onDismiss: playPending) { selection in
            ProgrammeDetailView(channel: selection.channel, programmeID: selection.programmeID) { catchup in
                pendingPlay = (selection.channel, catchup)
                self.selection = nil
            }
        }
    }

    private func scrollToNow(animated: Bool) {
        let x = scale.scrollX(toShow: .now, viewportWidth: viewportWidth - metrics.channelWidth)
        if animated {
            withAnimation(.snappy) { scroll(toX: x) }
        } else {
            scroll(toX: x)
        }
    }

    /// Scrolls sideways only. `scrollTo(x:)` would also reset the vertical offset to 0, which puts the top rows
    /// under the bars, so the current offset goes along.
    private func scroll(toX x: CGFloat) {
        position.scrollTo(point: CGPoint(x: x, y: offset.point.y))
    }

    private func play(_ channel: Channel, catchup: Programme? = nil) {
        model.play(channel, in: context, catchup: catchup)
    }

    private func playPending() {
        guard let pendingPlay else { return }
        self.pendingPlay = nil
        play(pendingPlay.channel, catchup: pendingPlay.catchup)
    }

    struct Selection: Identifiable {
        var channel: Channel
        var programmeID: Int64
        var id: Int64 { programmeID }
    }

    private final class OffsetBox {
        var point = CGPoint.zero
    }

    private struct RangeQuery: Equatable {
        var sourceID: Int64
        var guideIDs: Set<String>
    }

    private struct SlotQuery: Equatable {
        var sourceID: Int64
        var guideIDs: Set<String>
        var window: DateInterval
    }
}

// MARK: - Pinning

private extension View {
    /// Keeps the view at the left edge of the scroll view while the content scrolls sideways under it.
    func pinnedToLeadingEdge() -> some View {
        visualEffect { content, proxy in
            content.offset(x: max(-proxy.frame(in: .scrollView).minX, 0))
        }
        .zIndex(1)
    }
}

// MARK: - Ruler

/// The half-hour times along the top, with the day at midnight and a red mark at now.
private struct GuideRuler: View {
    let scale: GuideTimeScale
    let window: DateInterval
    let metrics: GuideMetrics
    let now: Date

    var body: some View {
        HStack(spacing: 0) {
            Text(window.start.addingTimeInterval(GuideTimeScale.loadMargin).formatted(.dateTime.weekday(.abbreviated).day()))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: metrics.channelWidth, height: metrics.rulerHeight)
                .background(.background)
                .pinnedToLeadingEdge()
            ZStack(alignment: .leading) {
                ForEach(scale.marks(from: window.start, to: window.end), id: \.self) { mark in
                    HStack(spacing: 4) {
                        Rectangle()
                            .fill(.separator)
                            .frame(width: 1, height: 10)
                        Text(Self.label(for: mark))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    .offset(x: scale.x(for: mark))
                }
                if (scale.start...scale.end).contains(now) {
                    Capsule()
                        .fill(.red)
                        .frame(width: 10, height: 6)
                        .offset(x: scale.x(for: now) - 5, y: metrics.rulerHeight / 2 - 3)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: scale.totalWidth, height: metrics.rulerHeight, alignment: .leading)
        }
        .background(.background)
        .overlay(alignment: .bottom) { Divider() }
    }

    private static func label(for mark: Date) -> String {
        let calendar = Calendar.current
        if calendar.component(.hour, from: mark) == 0, calendar.component(.minute, from: mark) == 0 {
            return mark.formatted(.dateTime.weekday(.abbreviated).day())
        }
        return mark.formatted(.dateTime.hour().minute())
    }
}

// MARK: - Rows

/// One channel: its pinned logo cell, then its programmes laid out along the timeline.
private struct GuideRow: View, Equatable {
    let channel: Channel
    let slots: [GuideSlot]
    let scale: GuideTimeScale
    let metrics: GuideMetrics
    let now: Date
    let onPlay: () -> Void
    let onSelect: (GuideSlot) -> Void

    /// The closures only ever do the same thing for the same channel, so they don't count.
    nonisolated static func == (lhs: GuideRow, rhs: GuideRow) -> Bool {
        lhs.channel == rhs.channel && lhs.slots == rhs.slots && lhs.scale == rhs.scale && lhs.metrics == rhs.metrics
            && lhs.now == rhs.now
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onPlay) {
                HStack(spacing: 10) {
                    VStack(spacing: 2) {
                        ChannelLogo(url: channel.logoURL, name: channel.name)
                            .frame(width: 52, height: metrics.showsNames ? 38 : 34)
                        // Too narrow for the name beside the logo: a short line under it tells channels apart.
                        if !metrics.showsNames {
                            Text(channel.number.map(String.init) ?? channel.name)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .truncationMode(.middle)
                        }
                    }
                    if metrics.showsNames {
                        Text(channel.name)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 10)
                .frame(width: metrics.channelWidth, height: metrics.rowHeight, alignment: metrics.showsNames ? .leading : .center)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .background(.background)
            .overlay(alignment: .trailing) { Divider() }
            .accessibilityLabel("Watch \(channel.name)")
            .pinnedToLeadingEdge()

            ZStack(alignment: .leading) {
                if slots.isEmpty {
                    Color.secondary.opacity(0.04)
                }
                ForEach(slots) { slot in
                    if let frame = scale.frame(start: slot.start, stop: slot.stop) {
                        GuideCell(slot: slot, width: frame.width, height: metrics.rowHeight, leadingInset: metrics.channelWidth,
                                  isPlayable: channel.isCatchupPlayable(startingAt: slot.start, now: now), now: now) {
                            onSelect(slot)
                        }
                        .offset(x: frame.x)
                    }
                }
                Rectangle()
                    .fill(.red)
                    .frame(width: 2)
                    .offset(x: scale.x(for: now) - 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .frame(width: scale.totalWidth, height: metrics.rowHeight, alignment: .leading)
        }
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// A programme in the grid. Past ones are dimmed unless the archive still has them; the one on air is tinted.
private struct GuideCell: View {
    let slot: GuideSlot
    let width: CGFloat
    let height: CGFloat
    /// Where the visible timeline starts in the scroll view, right of the channel column.
    let leadingInset: CGFloat
    let isPlayable: Bool
    let now: Date
    let action: () -> Void

    var body: some View {
        let stop = slot.stop ?? slot.start.addingTimeInterval(3600)
        let isOnAir = slot.start <= now && now < stop
        let isPast = stop <= now
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                if width > 28 {
                    HStack(spacing: 4) {
                        if isPlayable, !isOnAir {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.caption2)
                                .foregroundStyle(.tint)
                        }
                        Text(slot.title)
                            .font(.subheadline.weight(.medium))
                    }
                    Text(Self.timeRange(slot.start, stop))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(width: max(width - 3, 0), height: height - 6, alignment: .leading)
            // A programme that began off screen keeps its title in view, as long as some of the cell is left.
            .visualEffect { [leadingInset, width] content, proxy in
                let hidden = leadingInset - proxy.frame(in: .scrollView).minX
                return content.offset(x: min(max(hidden, 0), max(width - 90, 0)))
            }
            .clipped()
            .background(background(isOnAir: isOnAir, isPast: isPast), in: .rect(cornerRadius: 8))
            .opacity(isPast && !isPlayable ? 0.55 : 1)
            .padding(.leading, 1.5)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(slot.title), \(Self.timeRange(slot.start, stop))")
        .accessibilityHint(isPlayable ? "Catch-up available" : "")
    }

    private func background(isOnAir: Bool, isPast: Bool) -> Color {
        if isOnAir { return .accentColor.opacity(0.22) }
        return .secondary.opacity(isPast ? 0.08 : 0.14)
    }

    private static let time = Date.FormatStyle.dateTime.hour().minute()

    private static func timeRange(_ start: Date, _ stop: Date) -> String {
        "\(start.formatted(time))–\(stop.formatted(time))"
    }
}
