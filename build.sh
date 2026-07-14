#!/bin/bash
# Builds ClaudeUsage.app — a menu-bar-only app (LSUIElement, no Dock icon).
#
#   ./build.sh              native only — matches this Mac, fastest
#   ./build.sh --universal  arm64 + x86_64, for a bundle that also runs on Intel
set -euo pipefail
cd "$(dirname "$0")"

APP="ClaudeUsage.app"
UNIVERSAL=false
[ "${1:-}" = "--universal" ] && UNIVERSAL=true

if $UNIVERSAL; then
    # `swift build --arch a --arch b` would be the obvious way, but it needs
    # xcbuild from full Xcode; --triple only needs the Command Line Tools, so
    # build each slice separately and lipo them. Separate scratch paths keep the
    # two from overwriting each other's artifacts.
    echo "building arm64…"
    swift build -c release --triple arm64-apple-macosx14.0 --scratch-path .build-arm
    echo "building x86_64…"
    swift build -c release --triple x86_64-apple-macosx14.0 --scratch-path .build-x86
    BIN=$(mktemp -t ClaudeUsage)
    lipo -create \
        .build-arm/arm64-apple-macosx/release/ClaudeUsage \
        .build-x86/x86_64-apple-macosx/release/ClaudeUsage \
        -output "$BIN"
else
    swift build -c release
    BIN=.build/release/ClaudeUsage
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeUsage"
$UNIVERSAL && rm -f "$BIN"
echo "architectures: $(lipo -archs "$APP/Contents/MacOS/ClaudeUsage")"

# Optional custom menu bar icon. Without it the app falls back to an SF Symbol.
if [ -f Resources/MenuIcon.png ]; then
    cp Resources/MenuIcon.png "$APP/Contents/Resources/MenuIcon.png"
    echo "menu bar icon: Resources/MenuIcon.png"
else
    echo "menu bar icon: none — using SF Symbol fallback (see ./install-icon.sh)"
fi

# App icon: shown in Finder and System Settings > Login Items. The app is
# LSUIElement so it never reaches the Dock. Rebuild with ./make-appicon.py.
ICON_KEY=""
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
    ICON_KEY="    <key>CFBundleIconFile</key><string>AppIcon</string>"
    echo "app icon: Resources/AppIcon.icns"
else
    echo "app icon: none — generic icon in Finder (run ./make-appicon.py <image>)"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ClaudeUsage</string>
    <key>CFBundleDisplayName</key><string>Claude Usage</string>
    <key>CFBundleIdentifier</key><string>local.claude-usage</string>
    <key>CFBundleExecutable</key><string>ClaudeUsage</string>
$ICON_KEY
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Sign with the local self-signed identity when it exists.
#
# This is about TCC, not security theatre. macOS keys a permission grant to the
# app's designated requirement. Signed with a certificate that is
# (bundle id + certificate root) — identical across rebuilds, so a granted
# permission sticks. Ad-hoc signing keys on the cdhash instead, and the compiler
# emits a different binary on every recompile even for unchanged source, so each
# build looks like a brand new app and re-prompts for everything.
#
# Create the identity with ./make-signing-cert.sh.
IDENTITY="ClaudeUsage Self-Signed"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "signed: $IDENTITY (permissions survive rebuilds)"
else
    codesign --force --sign - "$APP" 2>/dev/null || true
    echo "signed: ad-hoc — macOS will re-ask for permissions after every rebuild"
    echo "        run ./make-signing-cert.sh once to fix that"
fi

echo "Built $APP — launch with: open $APP"
