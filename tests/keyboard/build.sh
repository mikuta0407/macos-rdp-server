#!/bin/bash
# Build the keyboard test tools into ./build/tests:
#   rdp-keytest   scripted RDP client (needs Homebrew freerdp + pkgconf)
#   KeyLogger.app key-event logger to run in the server's GUI session
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=build/tests
mkdir -p "$OUT/KeyLogger.app/Contents/MacOS"

clang -O1 -Wall -o "$OUT/rdp-keytest" tests/keyboard/rdp-keytest.c \
    $(pkg-config --cflags --libs freerdp3 winpr3)

clang -fobjc-arc -O1 -Wall -o "$OUT/KeyLogger.app/Contents/MacOS/KeyLogger" \
    tests/keyboard/KeyLogger.m -framework Cocoa -framework Carbon
cat > "$OUT/KeyLogger.app/Contents/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.macosrdp.keylogger</string>
  <key>CFBundleExecutable</key><string>KeyLogger</string>
  <key>CFBundleName</key><string>KeyLogger</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PL
codesign -s - --force "$OUT/KeyLogger.app" >/dev/null 2>&1 || true
echo "built: $OUT/rdp-keytest $OUT/KeyLogger.app"
