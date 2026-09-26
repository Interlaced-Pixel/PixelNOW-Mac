#!/bin/bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"
manifest_path="$repository_root/App/RemoteCoOp/remote-coop-direct-config.json"

test -f "$manifest_path"
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$manifest_path"

for required_key in '"topology"' '"networkConfiguration"' '"discovery"' '"admission"' '"signaling"' '"failurePolicy"'; do
    /usr/bin/grep -Fq "$required_key" "$manifest_path"
done

echo "Validated Remote Co-Op runtime manifest: $manifest_path"
