#!/bin/bash
set -euo pipefail

if [[ $# -lt 3 || $# -gt 4 ]]; then
    echo "Usage: $0 /path/to/Sparkle/bin /path/to/update-archives /path/to/appcast.xml [download-url-prefix]" >&2
    exit 2
fi

sparkle_bin="$1"
updates_directory="$2"
appcast_path="$3"
generate_appcast="$sparkle_bin/generate_appcast"
download_url_prefix="${4:-}"

if [[ ! -x "$generate_appcast" ]]; then
    echo "error: generate_appcast was not found at $generate_appcast" >&2
    exit 1
fi

if [[ ! -d "$updates_directory" ]]; then
    echo "error: update archive directory does not exist: $updates_directory" >&2
    exit 1
fi

if [[ -n "$download_url_prefix" ]]; then
    exec "$generate_appcast" -o "$appcast_path" --download-url-prefix "$download_url_prefix" "$updates_directory"
fi

exec "$generate_appcast" -o "$appcast_path" "$updates_directory"
