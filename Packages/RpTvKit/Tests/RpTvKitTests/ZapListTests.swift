// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing
@testable import RpTvKit

struct ZapListTests {
    private let channels = ["a", "b", "c"].enumerated().map { index, key in
        Channel(sourceID: 1, stableKey: key, name: key.uppercased(), sortIndex: index)
    }

    @Test func movesToNextAndPrevious() {
        let list = ZapList(channels: channels, currentKey: "b")
        #expect(list.neighbor(1)?.stableKey == "c")
        #expect(list.neighbor(-1)?.stableKey == "a")
        #expect(list.positionLabel == "2 of 3")
    }

    @Test func wrapsAroundAtTheEnds() {
        #expect(ZapList(channels: channels, currentKey: "c").neighbor(1)?.stableKey == "a")
        #expect(ZapList(channels: channels, currentKey: "a").neighbor(-1)?.stableKey == "c")
    }

    @Test func hasNowhereToGoWithOneChannel() {
        let list = ZapList(channels: [channels[0]], currentKey: "a")
        #expect(list.neighbor(1) == nil)
        #expect(list.neighbor(-1) == nil)
    }

    @Test func startsFromAnEndWhenCurrentChannelIsGone() {
        let list = ZapList(channels: channels, currentKey: "gone")
        #expect(list.neighbor(1)?.stableKey == "a")
        #expect(list.neighbor(-1)?.stableKey == "c")
        #expect(list.positionLabel == nil)
    }

    @Test func keepsCurrentChannelWhenListIsReplaced() {
        var list = ZapList(channels: [channels[0]], currentKey: "b")
        list.replaceChannels(channels)
        #expect(list.currentIndex == 1)
        list.select("c")
        #expect(list.neighbor(1)?.stableKey == "a")
    }
}
