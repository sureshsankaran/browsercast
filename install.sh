#!/bin/bash
# BrowserCast installer — run this ON the Mac mini (`bash install.sh` from the
# project folder). Builds the app with the Swift compiler from Xcode Command
# Line Tools, installs to ~/Applications, launches at login.
# Log: ~/Library/Logs/BrowserCast-install.log
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$HOME/Library/Logs/BrowserCast-install.log"
mkdir -p "$HOME/Library/Logs"
exec > >(tee -a "$LOG") 2>&1
echo "=== BrowserCast install $(date) ==="

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Xcode Command Line Tools not found — installing (a system dialog will appear)…"
  xcode-select --install || true
  echo "Finish that install, then run this script again."
  exit 1
fi

echo "Stopping any running BrowserCast…"
launchctl unload "$HOME/Library/LaunchAgents/com.muse.browsercast.plist" >/dev/null 2>&1 || true
pkill -x BrowserCast >/dev/null 2>&1 || true
sleep 1

APP="$HOME/Applications/BrowserCast.app"
BUILD="$(mktemp -d)"
echo "Building…"
swiftc -O -o "$BUILD/BrowserCast" "$SRC_DIR"/Sources/*.swift

echo "Assembling $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BUILD/BrowserCast" "$APP/Contents/MacOS/BrowserCast"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>BrowserCast</string>
  <key>CFBundleDisplayName</key><string>BrowserCast</string>
  <key>CFBundleIdentifier</key><string>com.muse.browsercast</string>
  <key>CFBundleVersion</key><string>1.1.1</string>
  <key>CFBundleShortVersionString</key><string>1.1.1</string>
  <key>CFBundleExecutable</key><string>BrowserCast</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "Ad-hoc signing…"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "(codesign skipped/failed — app will still run)"

echo "Installing LaunchAgent…"
PLIST_PATH="$HOME/Library/LaunchAgents/com.muse.browsercast.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.muse.browsercast</string>
  <key>ProgramArguments</key>
  <array><string>$APP/Contents/MacOS/BrowserCast</string></array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/BrowserCast.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/BrowserCast.log</string>
</dict>
</plist>
PLIST
launchctl unload "$PLIST_PATH" >/dev/null 2>&1 || true
launchctl load "$PLIST_PATH"

echo ""
echo "BrowserCast is installed and running (menu bar: 'Cast')."
echo "Next steps on this Mac:"
echo "  1. Allow BrowserCast under System Settings → Privacy & Security → Screen Recording, and → Accessibility (it prompts on first run)."
echo "  2. Keep BrowserOS open — the cast shows its window."
echo "  3. Menu bar → Cast → 'Copy Token (for Muse)' and paste the token to Muse in chat (once)."
echo "Done."
