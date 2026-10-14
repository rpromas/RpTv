// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Which half of the Library tab is showing.
enum LibraryKind: String, CaseIterable {
    case movies
    case series

    var title: String {
        switch self {
        case .movies: "Movies"
        case .series: "Series"
        }
    }

    static let storageKey = "libraryKind"
}

/// Movies and series in one tab, so the tab bar keeps room for Settings and Search on iPhone.
struct LibraryView: View {
    @AppStorage(LibraryKind.storageKey) private var kind = LibraryKind.movies

    var body: some View {
        switch kind {
        case .movies: MoviesView()
        case .series: SeriesView()
        }
    }
}

/// The Movies | Series switch in the middle of the Library's navigation bar.
struct LibrarySwitcher: ToolbarContent {
    @AppStorage(LibraryKind.storageKey) private var kind = LibraryKind.movies

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Library", selection: $kind) {
                ForEach(LibraryKind.allCases, id: \.self) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .accessibilityIdentifier("librarySwitcher")
        }
    }
}
