// swift-tools-version: 6.2
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import PackageDescription

// Turns streams AVPlayer can't open into local HLS it can, so AirPlay can carry their video. Built on FFmpeg,
// so it lives outside RpTvKit, which stays quick to test.
let package = Package(
    name: "StreamBridge",
    platforms: [
        .iOS("26.0"),
        // macOS so the pipeline can be tested quickly with `swift test`.
        .macOS("26.0"),
    ],
    products: [
        // Dynamic on purpose: VLCKit carries its own FFmpeg and exports the same symbols. Linked into the app
        // directly, some FFmpeg calls would bind to VLCKit's copy. As its own framework, StreamBridge binds every
        // FFmpeg call to Packages/FFmpeg when it's linked, whatever else the app contains.
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
