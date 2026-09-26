#!/bin/sh

set -eu

metadata_path="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/PixelNOWBuildMetadata.plist"
metadata_directory=$(dirname "$metadata_path")

repository_metadata="${SRCROOT:?}/.git"
head_contents=$(/bin/cat "$repository_metadata/HEAD")

case "$head_contents" in
	"ref: "*)
		head_reference=${head_contents#ref: }
		if [ -r "$repository_metadata/$head_reference" ]; then
			git_hash=$(/usr/bin/cut -c 1-8 "$repository_metadata/$head_reference")
		elif [ -r "$repository_metadata/packed-refs" ]; then
			git_hash=$(/usr/bin/awk -v reference="$head_reference" '$2 == reference { print substr($1, 1, 8); exit }' "$repository_metadata/packed-refs")
		else
			git_hash=Unavailable
		fi
		;;
	*)
		git_hash=$(/usr/bin/printf '%s' "$head_contents" | /usr/bin/cut -c 1-8)
		;;
esac

if [ -z "$git_hash" ]; then
	git_hash=Unavailable
fi
build_date=$(/bin/date -u '+%Y-%m-%d %H:%M UTC')

/bin/mkdir -p "$metadata_directory"
/bin/cat > "$metadata_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>gitHash</key>
	<string>${git_hash}</string>
	<key>buildDate</key>
	<string>${build_date}</string>
</dict>
</plist>
EOF
