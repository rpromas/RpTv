#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Builds FFmpeg from the Vendor/FFmpeg submodule into Packages/FFmpeg/FFmpeg.xcframework: one dynamic
# FFmpeg.framework per platform (iOS device, iOS simulator, macOS), LGPL components only.
#
# Usage: Scripts/build-ffmpeg.sh [--clean]
#
# Dynamic, so the app keeps meeting the LGPL: anyone can rebuild this framework from modified sources and drop
# it into the app. See THIRD_PARTY_NOTICES.md.

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/Vendor/FFmpeg"
WORK="$ROOT/build/ffmpeg"
OUT="$ROOT/Packages/FFmpeg/FFmpeg.xcframework"
MIN_IOS=26.0
MIN_MACOS=26.0
JOBS=$(sysctl -n hw.ncpu)

if [ ! -f "$SRC/configure" ]; then
    echo "Vendor/FFmpeg is empty. Run: git submodule update --init --depth 1" >&2
    exit 1
fi
if [ "${1:-}" = "--clean" ]; then
    rm -rf "$WORK"
fi

# Platform-specific hardware headers FFmpeg installs everywhere. They can't compile on Apple platforms, so they
# would break the framework's module.
FOREIGN_HEADERS='libavcodec/d3d11va.h libavcodec/dxva2.h libavcodec/vdpau.h libavcodec/qsv.h libavcodec/jni.h
libavcodec/mediacodec.h libavutil/hwcontext_cuda.h libavutil/hwcontext_d3d11va.h libavutil/hwcontext_d3d12va.h
libavutil/hwcontext_drm.h libavutil/hwcontext_dxva2.h libavutil/hwcontext_mediacodec.h libavutil/hwcontext_opencl.h
libavutil/hwcontext_qsv.h libavutil/hwcontext_vaapi.h libavutil/hwcontext_vdpau.h libavutil/hwcontext_vulkan.h
libavutil/hwcontext_amf.h libavutil/hwcontext_oh.h'

# $1 slice name, $2 SDK, $3 clang target triple
build_slice() {
    slice=$1 sdk=$2 triple=$3
    sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
    dir="$WORK/$slice"
    prefix="$dir/install"

    if [ ! -f "$prefix/lib/libavformat.a" ]; then
        echo "==> Configuring FFmpeg for $slice"
        rm -rf "$dir"
        mkdir -p "$dir"
        (
            cd "$dir"
            "$SRC/configure" \
                --prefix="$prefix" \
                --enable-cross-compile \
                --target-os=darwin \
                --arch=aarch64 \
                --cc="xcrun --sdk $sdk clang" \
                --sysroot="$sysroot" \
                --extra-cflags="-target $triple -fno-common" \
                --extra-ldflags="-target $triple" \
                --enable-static --disable-shared --enable-pic \
                --disable-programs --disable-doc --disable-debug \
                --disable-autodetect \
                --enable-videotoolbox --enable-audiotoolbox --enable-securetransport --enable-zlib \
                --enable-network \
                --disable-indevs --disable-outdevs
        ) > "$dir/configure.log" 2>&1 || { tail -30 "$dir/configure.log"; exit 1; }

        # Never ship GPL or nonfree code: the app is MPL-2.0 and links FFmpeg under the LGPL.
        if grep -qE '^#define CONFIG_(GPL|NONFREE) 1' "$dir/config.h"; then
            echo "FFmpeg was configured with GPL or nonfree components" >&2
            exit 1
        fi

        echo "==> Building FFmpeg for $slice"
        make -C "$dir" -j"$JOBS" > "$dir/build.log" 2>&1 || { tail -30 "$dir/build.log"; exit 1; }
        make -C "$dir" install > "$dir/install.log" 2>&1
    fi

    make_framework "$slice" "$sdk" "$triple" "$sysroot"
}

# Links the static libraries into one dynamic framework with headers and a module map.
make_framework() {
    slice=$1 sdk=$2 triple=$3 sysroot=$4
    prefix="$WORK/$slice/install"
    fw="$WORK/$slice/FFmpeg.framework"
    rm -rf "$fw"

    if [ "$sdk" = macosx ]; then
        # macOS frameworks use the versioned bundle layout.
        contents="$fw/Versions/A"
        mkdir -p "$contents/Resources"
        plist="$contents/Resources/Info.plist"
        install_name=@rpath/FFmpeg.framework/Versions/A/FFmpeg
        platform=MacOSX
    else
        contents="$fw"
        mkdir -p "$contents"
        plist="$contents/Info.plist"
        install_name=@rpath/FFmpeg.framework/FFmpeg
        platform=$( [ "$sdk" = iphoneos ] && echo iPhoneOS || echo iPhoneSimulator )
    fi

    # The system libraries each FFmpeg library needs, as configure recorded them.
    libs=$(sed -n 's/^EXTRALIBS-[a-z]*=//p' "$WORK/$slice/ffbuild/config.mak" | tr ' ' '\n' | awk 'NF' \
        | awk '/^-framework$/ { getline f; print "-framework " f; next } { print }' | sort -u | tr '\n' ' ')

    # FFmpeg compiles a few internal helpers into more than one library (fine for normal static linking, which
    # only pulls what's used). Loading every object into one dylib would define them twice, so drop any object
    # whose symbols an earlier library already provides.
    link="$WORK/$slice/link"
    rm -rf "$link"
    mkdir -p "$link"
    : > "$link/seen"
    archives=""
    for lib in avutil swresample swscale avcodec avformat avfilter; do
        archive="$link/lib$lib.a"
        cp "$prefix/lib/lib$lib.a" "$archive"
        nm -g -U -A "$archive" 2>/dev/null | awk '$NF ~ /^_/ { split($1, p, ":"); print p[2], $NF }' > "$link/symbols"
        awk 'NR == FNR { seen[$1] = 1; next } { total[$1]++; if ($2 in seen) dup[$1]++ }
             END { for (m in total) if (dup[m] == total[m]) print m }' "$link/seen" "$link/symbols" \
            | while read -r member; do ar -d "$archive" "$member"; done
        awk '{ print $2 }' "$link/symbols" >> "$link/seen"
        archives="$archives $archive"
    done

    # shellcheck disable=SC2086
    xcrun --sdk "$sdk" clang -dynamiclib -target "$triple" -isysroot "$sysroot" \
        -install_name "$install_name" \
        -Wl,-all_load $archives \
        $libs \
        -o "$contents/FFmpeg"

    mkdir -p "$contents/Headers" "$contents/Modules"
    cp -R "$prefix/include/" "$contents/Headers/"
    for header in $FOREIGN_HEADERS; do
        rm -f "$contents/Headers/$header"
    done
    # Headers include each other as "libavutil/x.h", which only resolves from the include root. Inside a
    # framework every header sits one directory down, so point them one level up.
    find "$contents/Headers" -name '*.h' -exec sed -i '' -E 's@#include "(libav[a-z]+|libsw[a-z]+)/@#include "../\1/@' {} +

    {
        echo '// Generated by Scripts/build-ffmpeg.sh.'
        (cd "$contents/Headers" && find . -name '*.h' | sed 's@^\./@@' | sort) | while read -r header; do
            echo "#include \"$header\""
        done
    } > "$contents/Headers/FFmpeg.h"
    cat > "$contents/Modules/module.modulemap" <<'EOF'
framework module FFmpeg {
    umbrella header "FFmpeg.h"
    export *
    module * { export * }
    link "z"
}
EOF

    version=$(cd "$SRC" && git describe --tags 2>/dev/null | sed 's/^n//' || echo 0)
    cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>FFmpeg</string>
    <key>CFBundleIdentifier</key><string>app.rptv.FFmpeg</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>FFmpeg</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$version</string>
    <key>CFBundleSupportedPlatforms</key><array><string>$platform</string></array>
    <key>MinimumOSVersion</key><string>$( [ "$sdk" = macosx ] && echo $MIN_MACOS || echo $MIN_IOS )</string>
</dict>
</plist>
EOF

    if [ "$sdk" = macosx ]; then
        ln -sfh A "$fw/Versions/Current"
        for item in FFmpeg Headers Modules Resources; do ln -sfh "Versions/Current/$item" "$fw/$item"; done
    fi
}

build_slice ios-arm64 iphoneos "arm64-apple-ios$MIN_IOS"
build_slice ios-arm64-simulator iphonesimulator "arm64-apple-ios$MIN_IOS-simulator"
build_slice macos-arm64 macosx "arm64-apple-macos$MIN_MACOS"

echo "==> Creating $OUT"
rm -rf "$OUT"
xcodebuild -create-xcframework \
    -framework "$WORK/ios-arm64/FFmpeg.framework" \
    -framework "$WORK/ios-arm64-simulator/FFmpeg.framework" \
    -framework "$WORK/macos-arm64/FFmpeg.framework" \
    -output "$OUT" > /dev/null
echo "Done."
