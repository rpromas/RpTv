# Third-party notices

RpTv is licensed under the [Mozilla Public License 2.0](LICENSE). It uses the following libraries.

| Library | License | Source |
| --- | --- | --- |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | MIT | Swift package |
| [Nuke](https://github.com/kean/Nuke) | MIT | Swift package |
| [FFmpeg](https://ffmpeg.org) | LGPL-2.1-or-later | Built from source, tag `n9.0.2` (`Vendor/FFmpeg` submodule) |

## FFmpeg and the LGPL

FFmpeg is licensed under the
[GNU Lesser General Public License, version 2.1](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html)
or later. RpTv builds it **only with LGPL components**: `Scripts/build-ffmpeg.sh` never passes `--enable-gpl`
or `--enable-nonfree`, and stops if FFmpeg's configuration enables either. The app links FFmpeg
**dynamically**: the bundle contains it as `RpTv.app/Frameworks/FFmpeg.framework`.

FFmpeg's source code is in this repository as the `Vendor/FFmpeg` git submodule, pinned to the release tag
`n9.0.2` from <https://github.com/FFmpeg/FFmpeg> (a mirror of <https://git.ffmpeg.org/ffmpeg.git>). RpTv
doesn't modify FFmpeg. The exact build options are in `Scripts/build-ffmpeg.sh`.

### Using RpTv with a modified FFmpeg

1. Change the sources in `Vendor/FFmpeg`, or check out another FFmpeg version there.
2. Rebuild the framework, then the app:

   ```sh
   Scripts/build-ffmpeg.sh --clean
   xcodegen generate
   ```

The result must stay a dynamic framework named `FFmpeg`. You can also swap the framework in an existing build:
replace `RpTv.app/Frameworks/FFmpeg.framework` with your build, then re-sign the app with your own identity.
