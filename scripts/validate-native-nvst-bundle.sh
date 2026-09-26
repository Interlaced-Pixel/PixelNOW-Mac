#!/bin/bash
set -euo pipefail

app_path="${1:-}"
if [[ -z "$app_path" || ! -d "$app_path" ]]; then
    echo "Usage: $0 /path/to/PixelNOW.app" >&2
    exit 2
fi

info_plist="$app_path/Contents/Info.plist"
webrtc_framework="$app_path/Contents/Frameworks/WebRTC.framework"
runtime_manifest="$app_path/Contents/Resources/remote-coop-direct-config.json"
app_binary="$app_path/Contents/MacOS/PixelNOW"

for required_path in "$info_plist" "$webrtc_framework" "$runtime_manifest" "$app_binary"; do
    test -e "$required_path"
done

/usr/bin/plutil -lint "$info_plist" >/dev/null
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$runtime_manifest"
test -x "$app_binary"

echo "Validated PixelNOW native runtime bundle: $app_path"
