#!/bin/bash
set -euo pipefail

native_build_directory="$DERIVED_FILE_DIR/NVSTNativeBuild"
cmake_executable="$(command -v cmake || true)"
if [[ -z "$cmake_executable" ]]; then
    for candidate in /opt/homebrew/bin/cmake /usr/local/bin/cmake; do
        if [[ -x "$candidate" ]]; then
            cmake_executable="$candidate"
            break
        fi
    done
fi
if [[ -z "$cmake_executable" ]]; then
    echo "error: Building PixelNOW native dependencies requires CMake 3.25 or newer." >&2
    exit 1
fi

"$cmake_executable" -S "$SRCROOT/GFN/Native" -B "$native_build_directory" -G Xcode \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.10
/usr/bin/xcodebuild build -project "$native_build_directory/NVSTNative.xcodeproj" \
    -scheme NVSTNative -configuration "$CONFIGURATION" \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$native_build_directory/DerivedData" \
    CODE_SIGNING_ALLOWED=NO -quiet

native_framework="$native_build_directory/$CONFIGURATION/NVSTNative.framework"
if [[ ! -d "$native_framework" ]]; then
    echo "error: The NVST native build did not produce its framework." >&2
    exit 1
fi
/usr/bin/ditto "$native_framework" "$BUILT_PRODUCTS_DIR/NVSTNative.framework"
