// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import RpTvKit
import SwiftUI

/// Hands its content what's on now and next for a list of channels, with one query for the whole
/// list rather than one per row. It updates when the guide changes and at every minute boundary,
/// so "now" moves on and progress bars advance.
struct NowNextReader<Content: View>: View {
    let database: AppDatabase
    let channelIDs: [Int64]
    @ViewBuilder let content: (_ nowNext: [Int64: NowNext], _ now: Date) -> Content

    @State private var nowNext: [Int64: NowNext] = [:]
    @State private var now = Date.now

    var body: some View {
        content(nowNext, now)
            .task {
                while !Task.isCancelled {
                    let seconds = 60 - Date.now.timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
                    do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                    now = .now
                }
            }
            .task(id: Query(channelIDs: channelIDs, minute: Int(now.timeIntervalSince1970 / 60))) {
                // The guide is optional: on failure rows simply show no programme.
                do {
                    for try await value in database.observeNowNext(channelIDs: channelIDs, at: now) {
                        nowNext = value
                    }
                } catch {}
            }
    }

    private struct Query: Equatable {
        var channelIDs: [Int64]
        var minute: Int
    }
}
