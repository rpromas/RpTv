// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import RpTvKit
import SwiftUI

extension View {
    /// Adds "Add to Favorites" / "Remove from Favorites" to a row or poster, as a leading swipe (in lists)
    /// and in its context menu.
    func favoriteActions(for item: ItemKey) -> some View {
        modifier(FavoriteActions(item: item))
    }
}

private struct FavoriteActions: ViewModifier {
    let item: ItemKey

    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        // Swipe actions and context menus build lazily, outside `body`, where reading `@Environment` traps.
        let model = model
        let item = item
        let isFavorite = model.isFavorite(item)
        let button = Button(isFavorite ? "Remove from Favorites" : "Add to Favorites",
                            systemImage: isFavorite ? "star.slash" : "star") {
            model.toggleFavorite(item)
        }
        return content
            .swipeActions(edge: .leading) {
                button.tint(.yellow)
            }
            .contextMenu { button }
    }
}
