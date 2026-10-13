// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

extension StringProtocol {
    /// The string, or `nil` when it is empty.
    var nonEmpty: String? { isEmpty ? nil : String(self) }
}

extension Optional where Wrapped: StringProtocol {
    var nonEmpty: String? { self?.nonEmpty }
}
