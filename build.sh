#!/bin/bash
# Builds ClaudeUsage.app — a menu-bar-only app (LSUIElement, no Dock icon).
#
#   ./build.sh              dev bundle in this folder, native arch
#   ./build.sh --universal  arm64 + x86_64, for a bundle that also runs on Intel
#   ./build.sh --install    also assemble the production bundle in /Applications
#
# The two bundles carry different identifiers on purpose — see BUNDLE IDS below.
set -euo pipefail
cd "$(dirname "$0")"

APP="ClaudeUsage.app"
DEST="/Applications/$APP"

# BUNDLE IDS
#
# macOS keys a login item to the bundle *identifier*, not the path, and records
# whichever bundle with that id launched last. With both copies sharing one id,
# simply opening the dev build silently repointed Launch at Login at this
# folder — a folder that build.sh deletes and recreates. Verified: set the login
# item to /Applications, open the dev copy, and the login item follows it here.
#
# Separate ids make that impossible: the dev copy cannot claim production's
# login item, and each gets its own TCC identity.
PROD_ID="local.claude-usage"
DEV_ID="local.claude-usage.dev"

UNIVERSAL=false
INSTALL=false
for arg in "$@"; do
    case "$arg" in
        --universal) UNIVERSAL=true ;;
        --install)   INSTALL=true ;;
        *) echo "unknown option: $arg"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------- compile

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
    trap 'rm -f "$BIN"' EXIT
    lipo -create \
        .build-arm/arm64-apple-macosx/release/ClaudeUsage \
        .build-x86/x86_64-apple-macosx/release/ClaudeUsage \
        -output "$BIN"
else
    swift build -c release
    BIN=.build/release/ClaudeUsage
fi

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
HAVE_CERT=false
security find-certificate -c "$IDENTITY" >/dev/null 2>&1 && HAVE_CERT=true

# ---------------------------------------------------------------- assemble

# assemble <dest> <bundle-id> <display-name>
#
# The two bundles differ only in Info.plist, but the plist is covered by the
# signature — so each has to be assembled and signed in place. Copying one over
# the other and patching the id would break the seal.
assemble() {
    local dest="$1" bundle_id="$2" display="$3"

    rm -rf "$dest"
    mkdir -p "$dest/Contents/MacOS" "$dest/Contents/Resources"
    cp "$BIN" "$dest/Contents/MacOS/ClaudeUsage"

    # Optional custom menu bar icon. Without it the app falls back to an SF Symbol.
    [ -f Resources/MenuIcon.png ] && cp Resources/MenuIcon.png "$dest/Contents/Resources/MenuIcon.png"

    # App icon: shown in Finder and System Settings > Login Items. The app is
    # LSUIElement so it never reaches the Dock. Rebuild with ./make-appicon.py.
    local icon_key=""
    if [ -f Resources/AppIcon.icns ]; then
        cp Resources/AppIcon.icns "$dest/Contents/Resources/AppIcon.icns"
        icon_key="    <key>CFBundleIconFile</key><string>AppIcon</string>"
    fi

    cat > "$dest/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ClaudeUsage</string>
    <key>CFBundleDisplayName</key><string>$display</string>
    <key>CFBundleIdentifier</key><string>$bundle_id</string>
    <key>CFBundleExecutable</key><string>ClaudeUsage</string>
$icon_key
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

    if $HAVE_CERT; then
        codesign --force --sign "$IDENTITY" "$dest" 2>/dev/null
    else
        codesign --force --sign - "$dest" 2>/dev/null || true
    fi
    echo "  $dest — $bundle_id"
}

echo "architectures: $(lipo -archs "$BIN")"
$HAVE_CERT || echo "signed: ad-hoc — run ./make-signing-cert.sh so permissions survive rebuilds"

echo "built:"
assemble "$APP" "$DEV_ID" "Claude Usage (dev)"

if $INSTALL; then
    # Only the production copy is touched here; the dev bundle above keeps its
    # own id and cannot disturb this one's login item.
    pkill -f "$DEST/Contents/MacOS/ClaudeUsage" 2>/dev/null || true
    sleep 1
    assemble "$DEST" "$PROD_ID" "Claude Usage"
    open "$DEST"
    sleep 2
    echo "Launch at Login: $("$DEST/Contents/MacOS/ClaudeUsage" --login-status 2>/dev/null || echo unknown)"
else
    echo
    echo "This is the dev copy. Install the production one with: ./build.sh --install"
fi
