#!/bin/zsh
# publish-mac.sh
# Builds the Mac release: ProxyPrintGenerator.app (Release, signed with
# this Mac's Apple Development certificate) zipped as
# release/ProxyPrintGenerator-<version>-mac.zip, ready to attach to the
# same GitHub release as the Windows zip. The Mac app's update check
# looks for exactly that name.
#
#   ./mac/publish-mac.sh
#
# Keep MARKETING_VERSION (Xcode: target > General > Version) the same as
# <Version> in ProxyPrintGenerator.csproj, and the release tag v<version>.

set -euo pipefail
here=${0:A:h}
root=${here:h}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT

xcodebuild -project "$here/ProxyPrintGenerator.xcodeproj" \
    -scheme ProxyPrintGenerator -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$build" build | grep -E "error:|BUILD" || true

app="$build/Build/Products/Release/ProxyPrintGenerator.app"
[[ -d $app ]] || { echo "Build failed: no ProxyPrintGenerator.app"; exit 1; }

version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")
csproj=$(sed -n 's:.*<Version>\(.*\)</Version>.*:\1:p' "$root/ProxyPrintGenerator.csproj" | head -1)
if [[ $version != $csproj ]]; then
    echo "Warning: Mac version $version doesn't match Windows version $csproj."
fi

codesign --verify --deep --strict "$app"
mkdir -p "$root/../release"
zip="$root/../release/ProxyPrintGenerator-$version-mac.zip"
rm -f "$zip"
# ditto keeps the code signature and bundle layout intact.
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
echo "Built ${zip:A}"
shasum -a 256 "$zip"
