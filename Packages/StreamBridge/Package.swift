// swift-tools-version: 6.2
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import PackageDescription

// Everything built on FFmpeg: the player for streams AVPlayer can't open (StreamPlayer), and the bridge that turns
// them into local HLS AVPlayer can play, so AirPlay can carry their video. Lives outside RpTvKit, which stays
// quick to test.
let package = Package(
    name: "StreamBridge",
    platforms: [
        .iOS("26.0"),
        // macOS so the pipeline can be tested quickly with `swift test`.
        .macOS("26.0"),
    ],
    products: [
        // Dynamic, so every FFmpeg call binds to Packages/FFmpeg when StreamBridge is linked, whatever else ends
        // up in the app.
        .library(name: "StreamBridge", type: .dynamic, targets: ["StreamBridge"]),
    ],
    dependencies: [
        .package(path: "../FFmpeg"),
    ],
    targets: [
        .target(
            name: "StreamBridge",
            dependencies: [
                .product(name: "FFmpeg", package: "FFmpeg"),
            ]
        ),
        .testTarget(
            name: "StreamBridgeTests",
            dependencies: ["StreamBridge", .product(name: "FFmpeg", package: "FFmpeg")],
            resources: [.copy("Fixtures")]
        ),
    ]
)
