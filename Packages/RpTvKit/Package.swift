// swift-tools-version: 6.2
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import PackageDescription

let package = Package(
    name: "RpTvKit",
    platforms: [
        .iOS("26.0"),
        // macOS is supported so the core can be tested quickly with `swift test`.
        .macOS("26.0"),
    ],
    products: [
        .library(name: "RpTvKit", targets: ["RpTvKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
    ],
    targets: [
        .target(
            name: "RpTvKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "RpTvKitTests",
            dependencies: ["RpTvKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
