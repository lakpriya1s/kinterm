#!/bin/sh
# Xcode's "Embed Browser" build phase: copy the browser built by
# Browser/build.sh into the app and sign it, and put `kinterm-browser` on
# the terminals' PATH (Contents/MacOS). Without a built browser, KinTerm is
# built without one.

set -eu

here="$SRCROOT/Browser"
built="$here/build/Frameworks"
app="$TARGET_BUILD_DIR/$WRAPPER_NAME"
frameworks="$app/Contents/Frameworks"
identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
[ -n "$identity" ] || identity="-"

sign() {
  codesign --force --sign "$identity" --timestamp=none "$@"
}

# The CLI and the MCP server script, always.
cp "$here/bin/kinterm-browser" "$app/Contents/MacOS/kinterm-browser"
mkdir -p "$app/Contents/Resources/browser"
cp "$here/bin/kinterm-browser-mcp.mjs" "$app/Contents/Resources/browser/"
sign "$app/Contents/MacOS/kinterm-browser"

# The KinTerm skill for agents, installed by the Setup Assistant.
mkdir -p "$app/Contents/Resources/agents/skills/kinterm"
cp "$SRCROOT/../agents/skills/kinterm/SKILL.md" "$app/Contents/Resources/agents/skills/kinterm/"

if [ ! -f "$built/KinTermBrowser.dylib" ]; then
  echo "note: No browser built (run macos/Browser/build.sh to include it)."
  rm -rf "$frameworks/Chromium Embedded Framework.framework" "$frameworks"/KinTerm\ Helper*.app \
    "$frameworks/KinTermBrowser.dylib"
  exit 0
fi

mkdir -p "$frameworks"
# Copy and sign only when the build changed: Chromium is 300 MB. (The
# stamp can't be in the app: everything there must be signed code.)
stamp="$TARGET_TEMP_DIR/KinTermBrowser.stamp"
if [ -f "$stamp" ] && [ -f "$frameworks/KinTermBrowser.dylib" ] && [ ! "$built/KinTermBrowser.dylib" -nt "$stamp" ] \
  && [ "$(cat "$stamp")" = "$(cat "$built/KinTermBrowser.version")|$identity" ]; then
  exit 0
fi

for item in "Chromium Embedded Framework.framework" "KinTermBrowser.dylib" \
  "KinTerm Helper.app" "KinTerm Helper (Alerts).app" "KinTerm Helper (GPU).app" \
  "KinTerm Helper (Plugin).app" "KinTerm Helper (Renderer).app"; do
  rsync -a --delete "$built/$item" "$frameworks/"
done

# Inside out: the framework's libraries, the framework, the helpers.
for lib in "$frameworks/Chromium Embedded Framework.framework/Versions/A/Libraries"/*.dylib; do
  sign "$lib"
done
sign "$frameworks/Chromium Embedded Framework.framework"
sign "$frameworks/KinTermBrowser.dylib"
for helper in "$frameworks"/KinTerm\ Helper*.app; do
  sign --options runtime --entitlements "$here/build/helper.entitlements" "$helper"
done

printf '%s|%s\n' "$(cat "$built/KinTermBrowser.version")" "$identity" >"$stamp"
