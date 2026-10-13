// swift-tools-version: 6.2
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import PackageDescription

// FFmpeg built from the Vendor/FFmpeg submodule. Run `Scripts/build-ffmpeg.sh` first: the XCFramework is a
// build product and isn't checked in.
let package = Package(
    name: "FFmpeg",
    platforms: [
        .iOS("26.0"),
        .macOS("26.0"),
    ],
    products: [
        .library(name: "FFmpeg", targets: ["FFmpeg"]),
    ],
    targets: [
        .binaryTarget(name: "FFmpeg", path: "FFmpeg.xcframework"),
        .testTarget(name: "FFmpegTests", dependencies: ["FFmpeg"]),
    ]
)
