#!/bin/sh
# Sign the browser inside a built KinTerm.app for release, before the app
# itself is signed: Chromium's libraries, its framework, the browser
# module and the helper apps (hardened runtime; the helpers get JIT for V8,
# see src/helper.entitlements), then the kinterm-browser CLI. Used by
# .github/workflows/kinterm-release.yml and scripts/release-mac.sh.
#
# Usage: macos/Browser/sign.sh <KinTerm.app> <signing identity>
#
# Does nothing for the browser in an app built without it.

set -eu

app=$1
identity=$2
here=$(cd "$(dirname "$0")" && pwd)

sign() {
  /usr/bin/codesign --force --timestamp --options runtime --sign "$identity" "$@"
}

frameworks="$app/Contents/Frameworks"
fw="$frameworks/Chromium Embedded Framework.framework"
if [ -d "$fw" ]; then
  for lib in "$fw/Versions/A/Libraries"/*.dylib; do
    sign "$lib"
  done
  sign "$fw"
  sign "$frameworks/KinTermBrowser.dylib"
  for helper in "$frameworks"/KinTerm\ Helper*.app; do
    sign --entitlements "$here/src/helper.entitlements" "$helper"
  done
fi

if [ -f "$app/Contents/MacOS/kinterm-browser" ]; then
  sign "$app/Contents/MacOS/kinterm-browser"
fi
