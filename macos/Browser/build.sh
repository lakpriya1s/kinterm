#!/bin/sh
# Build KinTerm's browser: download Chromium (CEF), build the browser module
# and Chromium's helper apps, and put them in Browser/build/Frameworks for
# the "Embed Browser" build phase to copy into KinTerm.app.
#
# Usage: Browser/build.sh [--clean]
#
# Without this, KinTerm builds and runs as before, just without the browser.
# Set CEF_ROOT to use a CEF binary distribution you already have.

set -eu

CEF_VERSION="156.0.28+g57389f0+chromium-156.0.8078.88"
CEF_SHA256_ARM64="840d05646fc88d986c3ce9f8fe87e6388607239180fc3e14e221cefd05c12e87"
CEF_PLATFORM="macosarm64"
ARCH="arm64"
MIN_MACOS="13.0"

here=$(cd "$(dirname "$0")" && pwd)
build="$here/build"
out="$build/Frameworks"

if [ "${1:-}" = "--clean" ]; then
  rm -rf "$build"
  shift
fi

if [ "$(uname -m)" != "arm64" ]; then
  echo "The browser is only built for Apple silicon so far." >&2
  exit 1
fi

# 1. Chromium, checked against its published SHA-256.
if [ -z "${CEF_ROOT:-}" ]; then
  CEF_ROOT="$here/.cef/$CEF_VERSION"
  if [ ! -d "$CEF_ROOT/Release" ]; then
    name="cef_binary_${CEF_VERSION}_${CEF_PLATFORM}_minimal"
    url="https://cef-builds.spotifycdn.com/$(printf '%s' "$name" | sed 's/+/%2B/g').tar.bz2"
    mkdir -p "$here/.cef"
    tarball="$here/.cef/$name.tar.bz2"
    echo "Downloading Chromium Embedded Framework $CEF_VERSION…"
    curl -fL --progress-bar "$url" -o "$tarball"
    echo "$CEF_SHA256_ARM64  $tarball" | shasum -a 256 -c -
    rm -rf "$here/.cef/$name" "$CEF_ROOT"
    tar -xjf "$tarball" -C "$here/.cef"
    mv "$here/.cef/$name" "$CEF_ROOT"
    rm "$tarball"
  fi
fi
framework="$CEF_ROOT/Release/Chromium Embedded Framework.framework"
[ -d "$framework" ] || { echo "No CEF framework in $CEF_ROOT" >&2; exit 1; }

flags="-arch $ARCH -mmacosx-version-min=$MIN_MACOS -O2 -DNDEBUG -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS -D_FILE_OFFSET_BITS=64 -fno-strict-aliasing -fstack-protector -fvisibility=hidden -I$CEF_ROOT"
cxxflags="-std=c++20 -fno-exceptions -fno-rtti -fno-threadsafe-statics -fvisibility-inlines-hidden -fobjc-call-cxx-cdtors -Wno-narrowing -Wno-undefined-var-template"

# 2. CEF's C++ wrapper, as a static library. Only changed files rebuild.
objdir="$build/obj/$CEF_VERSION"
mkdir -p "$objdir"
wrapper="$objdir/libcef_dll_wrapper.a"
(cd "$CEF_ROOT" && find libcef_dll -name '*.cc' -o -name '*.mm' | grep -v -e '_win\.cc$' -e '_linux\.cc$') |
  while read -r src; do
    obj="$objdir/$(printf '%s' "$src" | tr '/' '_').o"
    if [ ! -f "$obj" ] || [ "$CEF_ROOT/$src" -nt "$obj" ]; then
      printf '%s\n%s\n' "$src" "$obj"
    fi
  done | xargs -n 2 -P "$(sysctl -n hw.ncpu)" sh -c \
    "clang++ $flags $cxxflags -DWRAPPING_CEF_SHARED -c \"$CEF_ROOT/\$0\" -o \"\$1\"" 
if [ ! -f "$wrapper" ] || [ -n "$(find "$objdir" -name '*.o' -newer "$wrapper" | head -1)" ]; then
  rm -f "$wrapper"
  ar rcs "$wrapper" "$objdir"/*.o
fi

# 3. The browser module KinTerm loads, and the helper executable.
mkdir -p "$out"
clang++ $flags $cxxflags -fobjc-arc -dynamiclib \
  -install_name "@rpath/KinTermBrowser.dylib" \
  "$here/src/kinterm_browser.mm" "$wrapper" \
  -framework Cocoa -framework IOSurface \
  -o "$out/KinTermBrowser.dylib"
clang++ $flags $cxxflags \
  "$here/src/helper_main.mm" "$wrapper" \
  -framework Cocoa \
  -o "$build/KinTerm Helper"

# 4. Chromium and its helper apps, as they go in KinTerm.app/Contents/Frameworks.
# As a versioned framework (Versions/A, with symlinks), the layout Xcode
# and codesign expect; CEF ships it flat.
fw="$out/Chromium Embedded Framework.framework"
mkdir -p "$fw/Versions/A"
rsync -a --delete "$framework/" "$fw/Versions/A/"
ln -sfh A "$fw/Versions/Current"
for item in "Chromium Embedded Framework" Libraries Resources; do
  ln -sfh "Versions/Current/$item" "$fw/$item"
done
for suffix in "" " (Alerts)" " (GPU)" " (Plugin)" " (Renderer)"; do
  name="KinTerm Helper$suffix"
  id_suffix=$(printf '%s' "$suffix" | tr -d ' ()' | tr '[:upper:]' '[:lower:]')
  identifier="com.kinterm.app.helper${id_suffix:+.$id_suffix}"
  app="$out/$name.app"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS"
  cp "$build/KinTerm Helper" "$app/Contents/MacOS/$name"
  sed -e "s/\${NAME}/$name/g" -e "s/\${IDENTIFIER}/$identifier/g" \
    "$here/src/helper-Info.plist" >"$app/Contents/Info.plist"
done
cp "$here/src/helper.entitlements" "$build/helper.entitlements"
echo "$CEF_VERSION" >"$out/KinTermBrowser.version"

echo "Built the browser in $out ($(du -sh "$out" | cut -f1))."
