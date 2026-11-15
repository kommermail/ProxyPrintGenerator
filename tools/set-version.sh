#!/bin/zsh
# set-version.sh: sets the version for both apps at once, on the Mac.
#
#   ./tools/set-version.sh 1.65.0
#
# Writes <Version> in ProxyPrintGenerator.csproj (Windows) and the app's
# MARKETING_VERSION in mac/ProxyPrintGenerator.xcodeproj (Mac). The PC's
# twin is tools\set-version.ps1. Commit and push afterwards.

set -euo pipefail
root=${0:A:h:h}
v=${1:-}
[[ $v =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "Usage: $0 1.65.0  (major.minor.patch)"; exit 1; }
sed -i '' -E "s#<Version>[^<]*</Version>#<Version>$v</Version>#" "$root/ProxyPrintGenerator.csproj"
# The app target's version; the test targets stay at 1.0.
sed -i '' -E "/\"MARKETING_VERSION\": \"1\.0\"/!s#\"MARKETING_VERSION\": \"[^\"]*\"#\"MARKETING_VERSION\": \"$v\"#" "$root/mac/ProxyPrintGenerator.xcodeproj/project.xcproj"
grep -h -E "<Version>|\"MARKETING_VERSION\": \"$v\"" "$root/ProxyPrintGenerator.csproj" "$root/mac/ProxyPrintGenerator.xcodeproj/project.xcproj" | sed 's/^ */  /'
echo "Both apps are now $v. Commit and push."
