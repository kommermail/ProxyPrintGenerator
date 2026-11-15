#!/bin/zsh
# publish-mac.sh
# Builds the Mac release: ProxyPrintGenerator.app (Release, signed with
# this Mac's Apple Development certificate) zipped as
# release/ProxyPrintGenerator-<version>-mac.zip, ready to attach to the
# same GitHub release as the Windows zip. The Mac app's update check
# looks for exactly that name.
#
#   ./mac/publish-mac.sh            build the zip
#   ./mac/publish-mac.sh --upload   build it and attach it to release v<version>
#
# --upload needs the GitHub CLI, signed in once: brew install gh, then
# gh auth login. It replaces a Mac zip of the same name already on the
# release. If there's no release v<version> yet, it makes a draft one;
# add the Windows zip and publish it on GitHub (the release check expects
# the Windows zip, and the apps ignore drafts).
#
# Keep MARKETING_VERSION (Xcode: target > General > Version) the same as
# <Version> in ProxyPrintGenerator.csproj, and the release tag v<version>.

set -euo pipefail
upload=false
[[ ${1:-} == --upload ]] && upload=true
if $upload; then
    command -v gh >/dev/null || { echo "Install the GitHub CLI first: brew install gh"; exit 1; }
    gh auth status >/dev/null 2>&1 || { echo "Sign in to GitHub first: gh auth login"; exit 1; }
fi
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

if $upload; then
    repo=kommermail/ProxyPrintGenerator
    tag="v$version"
    cd "$root"
    if gh release view "$tag" -R $repo >/dev/null 2>&1; then
        gh release upload "$tag" "$zip" -R $repo --clobber
        echo "Attached to release $tag: https://github.com/$repo/releases/tag/$tag"
    else
        gh release create "$tag" "$zip" -R $repo --draft --target main \
            --title "ProxyPrintGenerator $version" \
            --notes "ProxyPrintGenerator $version for Windows and Mac."
        echo "Made a draft release $tag with the Mac zip. Add the Windows zip and publish it:"
        echo "  https://github.com/$repo/releases"
    fi
fi
