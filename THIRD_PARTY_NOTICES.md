# Third-party notices

RpTv is licensed under the [Mozilla Public License 2.0](LICENSE). It uses the following libraries.

| Library | License | Source |
| --- | --- | --- |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | MIT | Swift package |
| [Nuke](https://github.com/kean/Nuke) | MIT | Swift package |
| [VLCKit](https://code.videolan.org/videolan/VLCKit) | LGPL-2.1-or-later | Official VideoLAN binary, `4.0.0-a25` |

## VLCKit and the LGPL

VLCKit (and the libVLC it contains) is licensed under the
[GNU Lesser General Public License, version 2.1](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html)
or later. RpTv doesn't modify VLCKit. It uses the unmodified binary that VideoLAN publishes, and links it
**dynamically**: the app bundle contains it as `RpTv.app/Frameworks/VLCKit.framework`.

VLCKit's complete source code is available from VideoLAN at
<https://code.videolan.org/videolan/VLCKit> (tag `4.0.0-a25`). RpTv's complete source code is available in
this repository.

### Using RpTv with a modified VLCKit

The LGPL lets you replace VLCKit with a version you changed. To build RpTv against your own VLCKit:

1. Check out VLCKit at the tag RpTv uses, and make your changes:

   ```sh
   git clone https://code.videolan.org/videolan/VLCKit.git
   cd VLCKit
   git checkout 4.0.0-a25
   ```

2. Build an XCFramework for iOS devices and the simulator with VLCKit's build script. See VLCKit's
   `README.md` and `./compileAndBuildVLCKit.sh -h` for requirements and options.

   ```sh
   ./compileAndBuildVLCKit.sh -f -r
   ```

   The result is `iOS/VLCKit.xcframework`. Your build must remain a dynamic framework named `VLCKit`, since
   RpTv imports the `VLCKit` module.

3. Point RpTv at your build. In `project.yml`, replace the `VLCKit` package with a local Swift package that
   wraps your framework. For example, create `LocalVLCKit/Package.swift`:

   ```swift
   // swift-tools-version: 5.9
   import PackageDescription

   let package = Package(
       name: "VLCKit",
       products: [.library(name: "VLCKit", targets: ["VLCKit"])],
       targets: [.binaryTarget(name: "VLCKit", path: "VLCKit.xcframework")]
   )
   ```

   Copy your `VLCKit.xcframework` next to it, then change the package entry in `project.yml`:

   ```yaml
   VLCKit:
     path: LocalVLCKit
   ```

4. Regenerate the project and build or run RpTv as usual (see [README.md](README.md#building)):

   ```sh
   xcodegen generate
   ```

You can also swap the framework in an existing build. Replace `RpTv.app/Frameworks/VLCKit.framework` with
your framework, then re-sign the app with your own identity. RpTv works with any VLCKit build that keeps
the same public interface.
