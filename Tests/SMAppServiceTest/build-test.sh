#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP="build/KanataBarTest.app"
BUNDLE_ID="com.kanata-bar.test"
HELPER_BUNDLE_ID="com.kanata-bar.test-helper"

case "${1:-build}" in
  clean)
    rm -rf build
    echo "Cleaned."
    exit 0
    ;;
  run)
    if [ ! -d "$APP" ]; then
      echo "Not built yet. Run: $0 build"
      exit 1
    fi
    echo "Running... (output goes to stdout, Ctrl+C to stop)"
    exec "$APP/Contents/MacOS/kanata-bar-t"
    ;;
  build) ;;
  *)
    echo "Usage: $0 [build|clean|run]"
    exit 1
    ;;
esac

echo "=== Building SMAppService test ==="

# Create app bundle structure
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Library/LaunchDaemons"

# Info.plist for the app
cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.kanata-bar.test</string>
    <key>CFBundleName</key>
    <string>KanataBarTest</string>
    <key>CFBundleExecutable</key>
    <string>kanata-bar-t</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

# Info.plist for the helper (will be embedded into binary)
cat > build/helper-info.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.kanata-bar.test-helper</string>
    <key>CFBundleName</key>
    <string>kanata-bar-t-helper</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
</dict>
</plist>
PLIST

# LaunchDaemon plist for the helper (lives inside the app bundle)
cat > "$APP/Contents/Library/LaunchDaemons/$HELPER_BUNDLE_ID.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.kanata-bar.test-helper</string>
    <key>BundleProgram</key>
    <string>Contents/MacOS/kanata-bar-t-helper</string>
    <key>MachServices</key>
    <dict>
        <key>com.kanata-bar.test-helper</key>
        <true/>
    </dict>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>com.kanata-bar.test</string>
    </array>
</dict>
</plist>
PLIST

# Compile app (protocol.swift is shared between app and helper)
echo "Compiling app..."
/usr/bin/swiftc -O \
  -o "$APP/Contents/MacOS/kanata-bar-t" \
  protocol.swift app.swift \
  -framework AppKit

# Compile helper with embedded Info.plist
echo "Compiling helper (with embedded Info.plist)..."
/usr/bin/swiftc -O \
  -o "$APP/Contents/MacOS/kanata-bar-t-helper" \
  protocol.swift helper.swift \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker build/helper-info.plist

# Sign both with ad-hoc signature
echo "Signing (ad-hoc)..."
codesign -s - -f --identifier "$HELPER_BUNDLE_ID" "$APP/Contents/MacOS/kanata-bar-t-helper"
codesign -s - -f --identifier "$BUNDLE_ID" "$APP"

echo ""
echo "=== Bundle structure ==="
find "$APP" -type f | sort

echo ""
echo "=== Code signatures ==="
codesign -dvv "$APP" 2>&1 | grep -E "^(Authority|Identifier|CDHash|TeamIdentifier)"
echo "---"
codesign -dvv "$APP/Contents/MacOS/kanata-bar-t-helper" 2>&1 | grep -E "^(Authority|Identifier|CDHash|TeamIdentifier)"

echo ""
echo "=== Helper embedded Info.plist ==="
launchctl plist __TEXT,__info_plist "$APP/Contents/MacOS/kanata-bar-t-helper" 2>&1 || \
  otool -s __TEXT __info_plist "$APP/Contents/MacOS/kanata-bar-t-helper"

echo ""
echo "Built: $APP"
echo "Run:   $0 run"
