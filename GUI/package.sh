#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

app="$PWD/build/ZFilter.app"
codesign --verify --deep --strict "$app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
output="$PWD/build/dist"
staging=$(mktemp -d "${TMPDIR:-/tmp}/filter-dmg.XXXXXX")
trap 'rm -rf "$staging"' EXIT
mkdir -p "$staging/volume" "$output"
ditto --norsrc --noextattr --noacl "$app" "$staging/volume/ZFilter.app"
ln -s /Applications "$staging/volume/Applications"
codesign --verify --deep --strict "$staging/volume/ZFilter.app"

disk_image="ZFilter-$version-macOS-arm64.dmg"
hdiutil create -quiet -volname ZFilter -srcfolder "$staging/volume" -fs APFS -format UDZO "$staging/$disk_image"
hdiutil verify -quiet "$staging/$disk_image"
mv "$staging/$disk_image" "$output/$disk_image"
cd "$output"
shasum -a 256 "$disk_image" > SHA256SUMS.txt
printf 'Packaged %s/%s\n' "$output" "$disk_image"
