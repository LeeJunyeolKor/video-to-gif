#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
app_bundle="$project_dir/dist/VideoToGIF.app"
contents_dir="$app_bundle/Contents"

swift build --package-path "$project_dir" -c release --product VideoToGIF
binary_dir=$(swift build --package-path "$project_dir" -c release --show-bin-path)

rm -rf "$app_bundle"
mkdir -p "$contents_dir/MacOS"
ditto "$binary_dir/VideoToGIF" "$contents_dir/MacOS/VideoToGIF"
ditto "$project_dir/Resources/Info.plist" "$contents_dir/Info.plist"

sign_identity=${VIDEO_TO_GIF_SIGN_IDENTITY:--}
if [ "$sign_identity" = "-" ]; then
    codesign --force --options runtime --sign - "$app_bundle"
else
    codesign --force --options runtime --timestamp --sign "$sign_identity" "$app_bundle"
fi

codesign --verify --deep --strict --verbose=2 "$app_bundle"
archive="$project_dir/dist/VideoToGIF.zip"
rm -f "$archive"
package_dir=$(mktemp -d "${TMPDIR:-/tmp}/VideoToGIF-package.XXXXXX")
trap 'rm -rf "$package_dir"' EXIT
ditto "$app_bundle" "$package_dir/VideoToGIF.app"
ditto "$project_dir/Distribution/README.txt" "$package_dir/README.txt"
ditto -c -k "$package_dir" "$archive"
printf 'Built %s\n' "$archive"
