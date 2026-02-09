#!/bin/bash
# Build HushType.dmg for direct distribution (outside the App Store).
#
# Creates a DMG with the app and an alias to /Applications so the user
# can drag-and-drop to install.
#
# Usage:
#   ./build-dmg.sh                          Build app first, then create DMG (ad-hoc signed)
#   ./build-dmg.sh --skip-build             Create DMG from existing HushType.app
#   ./build-dmg.sh --sign "Developer ID Application: Your Name (TEAMID)"
#                                           Sign with your Developer ID and notarize
#
# For full distribution, you need an Apple Developer account ($99/year) and must:
#   1. Sign with your Developer ID certificate (--sign flag)
#   2. Notarize with Apple (the script handles this automatically when signing)
#   3. Distribute the resulting .dmg

set -e

# Prevent cp/ditto from copying resource forks / extended attributes
export COPYFILE_DISABLE=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="HushType"
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"
DMG_NAME="$APP_NAME.dmg"
DMG_PATH="$SCRIPT_DIR/$DMG_NAME"
DMG_STAGING="$SCRIPT_DIR/.dmg-staging"
VOLUME_NAME="$APP_NAME"
# Use distribution entitlements (no App Sandbox) for Developer ID builds.
# The sandbox entitlements in HushType.entitlements would block Sparkle's
# installer and prevent CGEvent keystroke simulation.
ENTITLEMENTS="$SCRIPT_DIR/HushType-distribution.entitlements"

# Parse arguments
SKIP_BUILD=false
SIGN_IDENTITY=""
for arg in "$@"; do
    case $arg in
        --skip-build)
            SKIP_BUILD=true
            ;;
        --sign)
            # Next argument is the identity
            ;;
        *)
            # Check if previous arg was --sign
            if [ "$prev_arg" = "--sign" ]; then
                SIGN_IDENTITY="$arg"
            fi
            ;;
    esac
    prev_arg="$arg"
done

# Step 1: Build the app (unless --skip-build)
if [ "$SKIP_BUILD" = false ]; then
    echo "=== Building $APP_NAME ==="
    "$SCRIPT_DIR/build-app.sh"
fi

# Verify app bundle exists
if [ ! -d "$APP_BUNDLE" ]; then
    echo "ERROR: $APP_BUNDLE not found. Run ./build-app.sh first."
    exit 1
fi

# Step 2: Sign with Developer ID (if identity provided)
# Notarization requires: Developer ID signature, hardened runtime, and a secure timestamp.
# Sign the binary explicitly first, then the bundle (--deep is unreliable for propagating flags).
if [ -n "$SIGN_IDENTITY" ]; then
    echo "=== Signing with Developer ID ==="
    # Strip ALL metadata by copying to a clean bundle (ditto --noextattr strips
    # everything including SIP-protected attributes like com.apple.macl that
    # xattr -cr cannot remove). Also removes the ad-hoc _CodeSignature.
    # Copy the bundle to /tmp for signing — iCloud-synced folders (like ~/Documents)
    # continuously re-add extended attributes that codesign rejects.
    SIGN_DIR=$(mktemp -d)
    SIGN_BUNDLE="$SIGN_DIR/$APP_NAME.app"
    echo "  Copying to $SIGN_DIR (outside iCloud)…"
    ditto --norsrc --noextattr --noqtn "$APP_BUNDLE" "$SIGN_BUNDLE"

    # Sign embedded frameworks first (inside-out signing order required for notarization)
    if [ -d "$SIGN_BUNDLE/Contents/Frameworks/Sparkle.framework" ]; then
        echo "  Signing Sparkle.framework..."
        # Sign any XPC services inside Sparkle
        find "$SIGN_BUNDLE/Contents/Frameworks/Sparkle.framework" -name "*.xpc" -type d | while read xpc; do
            codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$xpc"
        done
        # Sign any helper executables inside Sparkle
        find "$SIGN_BUNDLE/Contents/Frameworks/Sparkle.framework" \( -name "Autoupdate" -o -name "Updater" -o -name "Installer" \) | while read helper; do
            if [ -f "$helper" ] && file "$helper" | grep -q "Mach-O"; then
                codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$helper"
            fi
        done
        # Sign the framework itself
        codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$SIGN_BUNDLE/Contents/Frameworks/Sparkle.framework"
    fi

    # Sign the main app bundle last (outermost)
    codesign --force --sign "$SIGN_IDENTITY" \
        --entitlements "$ENTITLEMENTS" \
        --options runtime \
        --timestamp \
        "$SIGN_BUNDLE"
    # Move signed bundle back
    rm -rf "$APP_BUNDLE"
    mv "$SIGN_BUNDLE" "$APP_BUNDLE"
    rm -rf "$SIGN_DIR"
    echo "  Signed with: $SIGN_IDENTITY"
fi

# Step 3: Create the DMG
echo "=== Creating DMG ==="

# Detach any previously mounted HushType volumes (leftover from failed runs)
hdiutil detach "/Volumes/$VOLUME_NAME" 2>/dev/null || true

# Clean previous artifacts
rm -rf "$DMG_STAGING"
rm -f "$DMG_PATH"

# Create staging directory with app, Applications alias, user guide, and background
mkdir -p "$DMG_STAGING"
# Use ditto instead of cp -R to properly preserve macOS app bundle
# metadata (resource forks, extended attributes, code signatures)
ditto "$APP_BUNDLE" "$DMG_STAGING/$APP_NAME.app"
ln -s /Applications "$DMG_STAGING/Applications"

# Include the User Guide if it exists (prefer PDF over docx)
USER_GUIDE_PDF="$SCRIPT_DIR/HushType-User-Guide.pdf"
USER_GUIDE_DOCX="$SCRIPT_DIR/HushType-User-Guide.docx"
if [ -f "$USER_GUIDE_PDF" ]; then
    cp "$USER_GUIDE_PDF" "$DMG_STAGING/HushType User Guide.pdf"
    echo "  Included: HushType User Guide.pdf"
elif [ -f "$USER_GUIDE_DOCX" ]; then
    cp "$USER_GUIDE_DOCX" "$DMG_STAGING/HushType User Guide.docx"
    echo "  Included: HushType User Guide.docx (PDF not found)"
fi

# Note: the DMG background image is copied onto the mounted volume later
# (not into staging) because Finder's AppleScript can't resolve hidden paths
# that were baked in via hdiutil create -srcfolder.
BG_IMAGE="$SCRIPT_DIR/dmg-background.png"

# Verify the app was copied
if [ ! -f "$DMG_STAGING/$APP_NAME.app/Contents/MacOS/$APP_NAME" ]; then
    echo "ERROR: App bundle copy failed — $DMG_STAGING/$APP_NAME.app is incomplete."
    rm -rf "$DMG_STAGING"
    exit 1
fi
echo "  Staged: $APP_NAME.app and Applications alias"

# Create a temporary read-write DMG in /tmp (avoids iCloud interference)
DMG_TEMP="$(mktemp -d)/.dmg-temp.dmg"

# Calculate size: total staging content + 20MB headroom for filesystem overhead
STAGING_SIZE_KB=$(du -sk "$DMG_STAGING" | cut -f1)
DMG_SIZE_KB=$(( STAGING_SIZE_KB + 51200 ))

hdiutil create -volname "$VOLUME_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDRW \
    -size "${DMG_SIZE_KB}k" \
    "$DMG_TEMP"

# Clean up staging (no longer needed — contents are in the DMG)
rm -rf "$DMG_STAGING"

# Mount the read-write DMG and configure Finder window layout
echo "  Configuring Finder layout…"
MOUNT_OUTPUT=$(hdiutil attach -readwrite -noverify "$DMG_TEMP")
MOUNT_DIR=$(echo "$MOUNT_OUTPUT" | grep '/Volumes/' | sed 's/.*\/Volumes/\/Volumes/')

# Copy background image directly onto the mounted volume.
# This must happen AFTER mounting (not in staging) because Finder's AppleScript
# can only resolve files that exist on the live filesystem of the mounted volume.
if [ -f "$BG_IMAGE" ]; then
    mkdir "$MOUNT_DIR/.background"
    cp "$BG_IMAGE" "$MOUNT_DIR/.background/background.png"
    echo "  Copied background image to volume"
fi

# Use AppleScript to set icon positions, window size, background image,
# and view mode so the user sees the classic "drag app to Applications" layout
# with the User Guide visible below.
#
# Layout (660×440 window):
#   - HushType.app at (140, 185) — left of centre
#   - Applications at (520, 185) — right of centre
#   - User Guide at (330, 345) — bottom centre
#   - Background image from .background/background.png
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {400, 150, 1060, 590}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 80
        set background picture of viewOptions to file ".background:background.png"
        set position of item "$APP_NAME.app" of container window to {140, 185}
        set position of item "Applications" of container window to {520, 185}
        try
            set position of item "HushType User Guide.pdf" of container window to {330, 345}
        end try
        try
            set position of item "HushType User Guide.docx" of container window to {330, 345}
        end try
        close
        open
        update without registering applications
    end tell
end tell
APPLESCRIPT

# The AppleScript "update without registering applications" can mark items
# with the hidden flag — clear it so Finder displays them
chflags nohidden "$MOUNT_DIR/$APP_NAME.app"
[ -f "$MOUNT_DIR/HushType User Guide.pdf" ] && chflags nohidden "$MOUNT_DIR/HushType User Guide.pdf"
[ -f "$MOUNT_DIR/HushType User Guide.docx" ] && chflags nohidden "$MOUNT_DIR/HushType User Guide.docx"

# Wait for .DS_Store to be flushed to disk
sync
sleep 2

# Unmount
hdiutil detach "$MOUNT_DIR"

# Convert to compressed read-only DMG (final distribution format)
hdiutil convert "$DMG_TEMP" -format UDZO -ov -o "$DMG_PATH"
rm -f "$DMG_TEMP"

# Step 4: Sign the DMG itself (if identity provided)
if [ -n "$SIGN_IDENTITY" ]; then
    echo "=== Signing DMG ==="
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"
fi

# Step 5: Notarize (if signed with Developer ID)
if [ -n "$SIGN_IDENTITY" ]; then
    echo ""
    echo "=== Notarization ==="
    echo "To notarize (required for distribution without Gatekeeper warnings):"
    echo ""
    echo "  # Submit for notarization"
    echo "  xcrun notarytool submit \"$DMG_PATH\" \\"
    echo "      --apple-id YOUR_APPLE_ID \\"
    echo "      --team-id YOUR_TEAM_ID \\"
    echo "      --password YOUR_APP_SPECIFIC_PASSWORD \\"
    echo "      --wait"
    echo ""
    echo "  # Staple the notarization ticket to the DMG"
    echo "  xcrun stapler staple \"$DMG_PATH\""
    echo ""
    echo "After stapling, the DMG is ready for distribution."
fi

echo ""
echo "=== Done! ==="
echo "DMG created at: $DMG_PATH"
DMG_SIZE=$(du -sh "$DMG_PATH" | cut -f1)
echo "  Size: $DMG_SIZE"
echo ""
echo "To test: open \"$DMG_PATH\""
echo "  The user drags $APP_NAME.app into the Applications folder."
