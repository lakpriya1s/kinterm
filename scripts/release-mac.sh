#!/bin/sh
# Builds a signed, notarized KinTerm-<version>.dmg on this Mac, without CI.
# See scope/RELEASING.md.
#
#   scripts/release-mac.sh 0.1.0
#
# Needs, once per Mac:
# - a "Developer ID Application" certificate for team L84DL8HSN6 in the
#   login keychain;
# - notarization credentials under a notarytool keychain profile (default
#   "burnarc-notary", the team's; NOTARY_PROFILE picks another):
#     xcrun notarytool store-credentials <profile> --team-id L84DL8HSN6
#
# The app gets KinTerm's update feed and Sparkle public key, so copies
# installed from this DMG take later updates once they're published.
#
# This builds GhosttyKit in ReleaseFast, which dev builds link too. Run
# scripts/dev-run.sh --core afterwards to go back to a debug core.
set -eu

VERSION=${1:?usage: scripts/release-mac.sh X.Y.Z}
case "$VERSION" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "Version must be X.Y.Z" >&2; exit 1 ;;
esac

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEAM=L84DL8HSN6
PROFILE=${NOTARY_PROFILE:-burnarc-notary}
SPARKLE_PUBLIC_KEY=I+15Sod1ZqusN/7p7LtpYJmTDPwT2k5kZtun2bhZSsU=
FEED_URL=https://lakpriya.com/kinterm/appcast.xml
OUT="$ROOT/macos/build/dmg"
APP="$ROOT/macos/build/Release/KinTerm.app"
DMG="$OUT/KinTerm-$VERSION.dmg"
# A UTC timestamp, so every build is newer than the last for the updater,
# committed or not. The release workflow uses the same scheme.
BUILD=$(date -u +%Y%m%d%H%M)
COMMIT=$(git -C "$ROOT" rev-parse --short HEAD)

IDENTITY=$(security find-identity -v -p codesigning | sed -n "s/.*\"\(Developer ID Application: .*($TEAM)\)\"/\1/p" | head -1)
[ -n "$IDENTITY" ] || {
  echo "No Developer ID Application certificate for team $TEAM in the keychain." >&2
  exit 1
}
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 || {
  echo "No notarization credentials under the profile \"$PROFILE\"." >&2
  echo "Run: xcrun notarytool store-credentials $PROFILE --team-id $TEAM" >&2
  exit 1
}

echo "==> Building GhosttyKit (ReleaseFast) for KinTerm $VERSION ($BUILD)"
(cd "$ROOT" && zig build -Doptimize=ReleaseFast -Demit-macos-app=false "-Dversion-string=$VERSION")

echo "==> Building the browser (Chromium)"
"$ROOT/macos/Browser/build.sh"

echo "==> Building KinTerm.app (Release)"
(cd "$ROOT/macos" && xcodebuild -target Ghostty -configuration Release -quiet)

echo "==> Setting version, update feed and key"
plist="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :GhosttyCommit $COMMIT" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$plist"
for key in SUPublicEDKey KinTermFeedURL SUEnableAutomaticChecks; do
  /usr/libexec/PlistBuddy -c "Delete :$key" "$plist" 2>/dev/null || true
done
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_KEY" "$plist"
/usr/libexec/PlistBuddy -c "Add :KinTermFeedURL string $FEED_URL" "$plist"

echo "==> Signing with $IDENTITY"
sign() { /usr/bin/codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@"; }
sparkle="$APP/Contents/Frameworks/Sparkle.framework"
for part in Versions/B/XPCServices/Downloader.xpc Versions/B/XPCServices/Installer.xpc \
  Versions/B/Autoupdate Versions/B/Updater.app; do
  sign "$sparkle/$part"
done
sign "$sparkle"
sign "$APP/Contents/PlugIns/DockTilePlugin.plugin"
"$ROOT/macos/Browser/sign.sh" "$APP" "$IDENTITY"
sign --entitlements "$ROOT/macos/Ghostty.entitlements" "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"

echo "==> Building $DMG"
rm -rf "$OUT"
STAGE="$OUT/stage"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/KinTerm.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "KinTerm" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --sign "$IDENTITY" --timestamp "$DMG"

echo "==> Notarizing (this takes a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

echo "==> Checking"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
echo "SHA-256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "Done: $DMG"
