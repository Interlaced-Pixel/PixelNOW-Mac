#!/bin/bash
set -euo pipefail

app_path="${1:-}"
if [[ -z "$app_path" || ! -d "$app_path" ]]; then
    echo "Usage: $0 /path/to/PixelNOW.app" >&2
    exit 2
fi

info_plist="$app_path/Contents/Info.plist"
native_framework="$app_path/Contents/Frameworks/NVSTNative.framework"
app_binary="$app_path/Contents/MacOS/PixelNOW"

for required_path in "$info_plist" "$native_framework/NVSTNative" "$native_framework/Resources/ThirdParty/Dependencies.json" "$app_binary"; do
    if [[ ! -e "$required_path" ]]; then
        echo "Missing native runtime component: $required_path" >&2
        exit 1
    fi
done

/usr/bin/plutil -lint "$info_plist" >/dev/null
test -x "$app_binary"
runtime_binaries=("$app_binary")
if [[ -f "$app_path/Contents/MacOS/PixelNOW.debug.dylib" ]]; then
    runtime_binaries+=("$app_path/Contents/MacOS/PixelNOW.debug.dylib")
fi
native_link_present=false
for runtime_binary in "${runtime_binaries[@]}"; do
    dependencies="$(/usr/bin/otool -L "$runtime_binary")"
    if /usr/bin/grep -q 'WebRTC.framework' <<< "$dependencies"; then
        echo "The native runtime still links WebRTC.framework: $runtime_binary" >&2
        exit 1
    fi
    if /usr/bin/grep -q '@rpath/NVSTNative.framework/' <<< "$dependencies"; then
        native_link_present=true
    fi
done
if [[ -e "$app_path/Contents/Frameworks/WebRTC.framework" ]]; then
    echo "The native runtime still embeds WebRTC.framework." >&2
    exit 1
fi
if [[ "$native_link_present" != true ]]; then
    echo "The native runtime does not link NVSTNative.framework." >&2
    exit 1
fi

echo "Validated PixelNOW native runtime bundle: $app_path"
