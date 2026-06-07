#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
APP="$DIR/ClaudeUsage.app"
ARCH="$(uname -m)"

cd "$DIR"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ClaudeUsage</string>
  <key>CFBundleDisplayName</key><string>Claude Usage</string>
  <key>CFBundleIdentifier</key><string>com.clawd.claudeusage</string>
  <key>CFBundleExecutable</key><string>ClaudeUsage</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "Compiling for ${ARCH}…"
swiftc -O \
  -parse-as-library \
  -target "${ARCH}-apple-macos13.0" \
  -o "$APP/Contents/MacOS/ClaudeUsage" \
  "$DIR/ClaudeUsageBar.swift" \
  "$DIR/ClaudeAnims.swift" \
  -framework SwiftUI -framework AppKit

pkill -f "ClaudeUsage.app/Contents/MacOS/ClaudeUsage" 2>/dev/null || true
sleep 0.3
open "$APP"
echo "Launched. Look in your menu bar (top-right) for the Claude spark."
