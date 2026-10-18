#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

BUNDLE="build/Kanata Bar.app"
BUNDLE_ID="com.kanata-bar"
HELPER_BUNDLE_ID="com.kanata-bar.helper"
VERSION="$(git describe --tags --always 2>/dev/null || echo "dev")"
VERSION="${VERSION#v}"  # strip leading 'v'

case "${1:-build}" in
  clean)
    rm -rf build .build
    echo "Cleaned."
    exit 0
    ;;
  run)
    if [ ! -d "$BUNDLE" ]; then
      echo "Not built yet. Run: $0 build" >&2
      exit 1
    fi
    echo "Running... (Ctrl+C to stop)"
    exec "$BUNDLE/Contents/MacOS/kanata-bar" "${@:2}"
    ;;
  release)
    ver="${2:?Usage: $0 release <version> (e.g. 0.2.0)}"
    ver="${ver#v}"
    tag="v$ver"
    if [ -n "$(git status --porcelain)" ]; then
      echo "error: working tree is dirty. Commit or stash your changes first." >&2
      exit 1
    fi
    if git rev-parse "$tag" >/dev/null 2>&1; then
      echo "error: tag $tag already exists" >&2
      exit 1
    fi
    echo "Tagging $tag and pushing..."
    git tag "$tag"
    git push origin "$tag"
    echo "Released $tag — CI will create the GitHub Release."
    exit 0
    ;;
  build) ;;
  *)
    echo "Usage: $0 [build|clean|run|release <version>]"
    exit 1
    ;;
esac

if ! command -v swift &>/dev/null; then
  echo "error: swift not found" >&2
  echo "Install Xcode Command Line Tools: xcode-select --install" >&2
  exit 1
fi
if ! command -v resvg &>/dev/null; then
  echo "error: resvg not found (needed to rasterize the app icon)" >&2
  echo "Install it: brew install resvg" >&2
  exit 1
fi

echo "=== Building kanata-bar $VERSION ==="

# Clean previous build
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Library/LaunchDaemons"
mkdir -p build

# --- Plists ---

cat > "$BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.kanata-bar</string>
    <key>CFBundleName</key>
    <string>Kanata Bar</string>
    <key>CFBundleExecutable</key>
    <string>kanata-bar</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

# Templated helper plist — overwrites the in-tree placeholder so the embedded
# `__info_plist` section carries the real version, not 0.0.0. SMAppService keys
# daemon registrations by version; without this, updates can keep the stale
# helper binary registered. Restored on exit so the working tree stays clean.
HELPER_PLIST="Resources/helper-info.plist"
HELPER_PLIST_BACKUP="$(mktemp)"
cp "$HELPER_PLIST" "$HELPER_PLIST_BACKUP"
trap 'mv "$HELPER_PLIST_BACKUP" "$HELPER_PLIST"' EXIT

cat > "$HELPER_PLIST" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.kanata-bar.helper</string>
    <key>CFBundleName</key>
    <string>kanata-bar-helper</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
</dict>
</plist>
PLIST

cat > "$BUNDLE/Contents/Library/LaunchDaemons/$HELPER_BUNDLE_ID.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.kanata-bar.helper</string>
    <key>BundleProgram</key>
    <string>Contents/MacOS/kanata-bar-helper</string>
    <key>MachServices</key>
    <dict>
        <key>com.kanata-bar.helper</key>
        <true/>
    </dict>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>com.kanata-bar</string>
    </array>
</dict>
</plist>
PLIST

# --- Icon ---

mkdir -p "$BUNDLE/Contents/Resources"
scripts/make-icns.sh Resources/icon/kanata-bar-icon-macos.svg "$BUNDLE/Contents/Resources/AppIcon.icns"
[ -f Resources/placeholder.png ] && cp Resources/placeholder.png "$BUNDLE/Contents/Resources/"
[ -f Resources/sign.png ] && cp Resources/sign.png "$BUNDLE/Contents/Resources/"
for lproj in Resources/*.lproj; do
  [ -d "$lproj" ] && cp -r "$lproj" "$BUNDLE/Contents/Resources/"
done

# --- Compile ---

echo "Compiling with Swift Package Manager..."
swift build -c release

cp .build/release/kanata-bar "$BUNDLE/Contents/MacOS/"
cp .build/release/kanata-bar-helper "$BUNDLE/Contents/MacOS/"

# --- Sign ---

# Signing identity: ad-hoc ("-") by default. Override with KANATA_BAR_SIGN_ID to
# sign with a real keychain identity — required for the SMAppService helper daemon
# to LAUNCH on a full-SIP machine (ad-hoc root daemons are rejected with
# OS_REASON_CODESIGNING; any cert-based signature, even self-signed, passes). For
# local full-SIP dev: KANATA_BAR_SIGN_ID=yabai-cert ./build.sh. Shipping still
# needs Developer ID + notarization. Sign inside-out: helper, then the bundle.
SIGN_ID="${KANATA_BAR_SIGN_ID:--}"
if [ "$SIGN_ID" = "-" ]; then
  echo "Signing (ad-hoc)..."
else
  echo "Signing (identity: $SIGN_ID)..."
fi
codesign -s "$SIGN_ID" -f --identifier "$HELPER_BUNDLE_ID" "$BUNDLE/Contents/MacOS/kanata-bar-helper"
codesign -s "$SIGN_ID" -f --identifier "$BUNDLE_ID" "$BUNDLE"

echo ""
echo "Built: $BUNDLE"
echo "Run:   $0 run [-- --config-file /path/to/config.toml --kanata /path/to/kanata --config /path/to/kanata.kbd --port 5829 --icons-dir /path/to/icons]"
