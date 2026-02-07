#!/bin/bash
# Build HushType and package it as a proper .app bundle
#
# Usage:
#   ./build-app.sh              Build for local testing (ad-hoc signed)
#   ./build-app.sh --sandbox    Build with App Sandbox entitlements (for App Store testing)
#
# For Mac App Store distribution, replace the ad-hoc signature ("-") with your
# Apple Developer signing identity:
#   codesign --force --sign "Developer ID Application: Your Name (TEAMID)" \
#       --entitlements "$ENTITLEMENTS" --options runtime "$APP_BUNDLE"

set -e

# Prevent cp from copying resource forks / extended attributes
export COPYFILE_DISABLE=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build/release"
APP_NAME="HushType"
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"
BUNDLED_MODELS="$SCRIPT_DIR/Sources/HushType/Resources/Models"
ENTITLEMENTS="$SCRIPT_DIR/Sources/HushType/Resources/HushType.entitlements"
INFO_PLIST="$SCRIPT_DIR/Sources/HushType/Resources/Info.plist"

# Parse arguments
SANDBOX_MODE=false
for arg in "$@"; do
    case $arg in
        --sandbox) SANDBOX_MODE=true ;;
    esac
done

echo "=== Building $APP_NAME (Release) ==="
cd "$SCRIPT_DIR"
swift build -c release

echo "=== Creating .app bundle ==="
# Clean previous bundle
rm -rf "$APP_BUNDLE"

# Create bundle structure
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy the binary
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy app icon if it exists
APP_ICON="$SCRIPT_DIR/Sources/HushType/Resources/AppIcon.icns"
if [ -f "$APP_ICON" ]; then
    echo "=== Including app icon ==="
    cp "$APP_ICON" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
else
    echo "=== No app icon found (run create-icns.py to generate one) ==="
fi

# Copy custom menu bar icon PNGs if they exist
MENUBAR_ICONS="$SCRIPT_DIR/Sources/HushType/Resources"
MENUBAR_FOUND=false
for icon in menubar-icon.png menubar-icon@2x.png menubar-icon-recording.png menubar-icon-recording@2x.png; do
    if [ -f "$MENUBAR_ICONS/$icon" ]; then
        cp "$MENUBAR_ICONS/$icon" "$APP_BUNDLE/Contents/Resources/$icon"
        MENUBAR_FOUND=true
    fi
done
if [ "$MENUBAR_FOUND" = true ]; then
    echo "=== Included custom menu bar icons ==="
else
    echo "=== No custom menu bar icons found ==="
fi

# Copy bundled models if they exist
if [ -d "$BUNDLED_MODELS" ] && [ "$(ls -A "$BUNDLED_MODELS" 2>/dev/null)" ]; then
    echo "=== Bundling models ==="
    ditto --norsrc "$BUNDLED_MODELS" "$APP_BUNDLE/Contents/Resources/Models"
    for model in "$APP_BUNDLE/Contents/Resources/Models"/*/; do
        if [ -d "$model" ]; then
            model_name=$(basename "$model")
            model_size=$(du -sh "$model" | cut -f1)
            echo "  Included: $model_name ($model_size)"
        fi
    done
else
    echo "=== No bundled models found (models will be downloaded on first use) ==="
    echo "  Run ./bundle-model.sh to include the small.en model in the app."
fi

# Copy Info.plist from source (single source of truth)
cp "$INFO_PLIST" "$APP_BUNDLE/Contents/Info.plist"

# Create PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Copy to /tmp for signing — iCloud-synced folders (like ~/Documents)
# continuously re-add extended attributes that codesign rejects.
SIGN_DIR=$(mktemp -d)
SIGN_BUNDLE="$SIGN_DIR/$APP_NAME.app"
ditto --norsrc --noextattr --noqtn "$APP_BUNDLE" "$SIGN_BUNDLE"

# Code-sign the app bundle (in /tmp, away from iCloud)
if [ "$SANDBOX_MODE" = true ]; then
    echo "=== Signing with App Sandbox entitlements ==="
    codesign --force --sign - --entitlements "$ENTITLEMENTS" "$SIGN_BUNDLE"
else
    echo "=== Signing (ad-hoc, no sandbox) ==="
    codesign --force --sign - "$SIGN_BUNDLE"
fi

# Move signed bundle back
rm -rf "$APP_BUNDLE"
mv "$SIGN_BUNDLE" "$APP_BUNDLE"
rm -rf "$SIGN_DIR"

echo ""
echo "=== Done! ==="
echo "App bundle created at: $APP_BUNDLE"
if [ "$SANDBOX_MODE" = true ]; then
    echo "  (Signed with App Sandbox entitlements)"
fi
echo ""
echo "To run:  open \"$APP_BUNDLE\""
echo ""
echo "To grant Accessibility permission:"
echo "  1. Open System Settings > Privacy & Security > Accessibility"
echo "  2. Click '+' and select: $APP_BUNDLE"
echo "  3. Or drag HushType.app from Finder into the list"
echo ""
echo "=== App Store Distribution ==="
echo "To prepare for the Mac App Store:"
echo "  1. Join the Apple Developer Program (\$99/year)"
echo "  2. Create an App ID and provisioning profile in App Store Connect"
echo "  3. Build with --sandbox flag: ./build-app.sh --sandbox"
echo "  4. Re-sign with your Developer ID:"
echo "     codesign --force --sign \"Developer ID Application: Your Name (TEAMID)\" \\"
echo "         --entitlements \"$ENTITLEMENTS\" --options runtime \"$APP_BUNDLE\""
echo "  5. Upload via Transporter or 'xcrun altool --upload-app'"
