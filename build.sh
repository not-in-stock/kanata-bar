#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

BUNDLE="build/Kanata Bar.app"
BUNDLE_ID="com.kanata-bar"
HELPER_BUNDLE_ID="com.kanata-bar.helper"
SWIFTC="/usr/bin/swiftc"
VERSION="$(git describe --tags --always 2>/dev/null || echo "dev")"
VERSION="${VERSION#v}"  # strip leading 'v'

case "${1:-build}" in
  clean)
    rm -rf build
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

if [ ! -x "$SWIFTC" ]; then
  echo "error: system swiftc not found at $SWIFTC" >&2
  echo "Install Xcode Command Line Tools: xcode-select --install" >&2
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

cat > build/helper-info.plist << PLIST
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
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/"
[ -f Resources/placeholder.png ] && cp Resources/placeholder.png "$BUNDLE/Contents/Resources/"
[ -f Resources/sign.png ] && cp Resources/sign.png "$BUNDLE/Contents/Resources/"
[ -d Resources/en.lproj ] && cp -r Resources/en.lproj "$BUNDLE/Contents/Resources/"

# --- Compile ---

echo "Compiling kanata-bar..."
$SWIFTC -O \
  -o "$BUNDLE/Contents/MacOS/kanata-bar" \
  Sources/Shared/Constants.swift \
  Sources/Shared/HelperProtocol.swift \
  Sources/App/main.swift \
  Sources/App/Config.swift \
  Sources/App/TOMLParser.swift \
  Sources/App/AppDelegate.swift \
  Sources/App/Menu.swift \
  Sources/App/MenuViews.swift \
  Sources/App/Icons.swift \
  Sources/App/Logging.swift \
  Sources/App/LaunchAgent.swift \
  Sources/App/KanataClient.swift \
  Sources/App/KanataProcess.swift \
  -framework AppKit \
  -framework Network \
  -framework ServiceManagement \
  -framework UserNotifications

echo "Compiling kanata-bar-helper..."
$SWIFTC -O \
  -o "$BUNDLE/Contents/MacOS/kanata-bar-helper" \
  Sources/Shared/Constants.swift \
  Sources/Shared/HelperProtocol.swift \
  Sources/Helper/main.swift \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker build/helper-info.plist

# --- Sign ---

echo "Signing (ad-hoc)..."
codesign -s - -f --identifier "$HELPER_BUNDLE_ID" "$BUNDLE/Contents/MacOS/kanata-bar-helper"
codesign -s - -f --identifier "$BUNDLE_ID" "$BUNDLE"

echo ""
echo "Built: $BUNDLE"
echo "Run:   $0 run [-- --config-file /path/to/config.toml --kanata /path/to/kanata --config /path/to/kanata.kbd --port 5829 --icons-dir /path/to/icons]"
