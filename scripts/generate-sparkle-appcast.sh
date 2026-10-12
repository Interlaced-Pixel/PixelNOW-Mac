#!/bin/bash
set -euo pipefail

if [[ $# -lt 3 || $# -gt 5 ]]; then
    echo "Usage: $0 /path/to/Sparkle/bin /path/to/update-archives /path/to/appcast.xml [download-url-prefix] [release-notes-url-prefix]" >&2
    exit 2
fi

sparkle_bin="$1"
updates_directory="$2"
appcast_path="$3"
generate_appcast="$sparkle_bin/generate_appcast"
download_url_prefix="${4:-}"
release_notes_url_prefix="${5:-}"
generator_options=()

if [[ -n "$download_url_prefix" ]]; then
    generator_options+=(--download-url-prefix "$download_url_prefix")
fi

if [[ -n "$release_notes_url_prefix" ]]; then
    generator_options+=(--release-notes-url-prefix "$release_notes_url_prefix")
fi

if [[ ! -x "$generate_appcast" ]]; then
    echo "error: generate_appcast was not found at $generate_appcast" >&2
    exit 1
fi

if [[ ! -d "$updates_directory" ]]; then
    echo "error: update archive directory does not exist: $updates_directory" >&2
    exit 1
fi

exec "$generate_appcast" -o "$appcast_path" "${generator_options[@]}" "$updates_directory"
