#!/bin/bash
# Release a new version of HushType.
#
# Usage:
#   ./release.sh <version>
#
# Example:
#   ./release.sh 1.1
#
# What it does:
#   1. Updates the version in Info.plist
#   2. Builds and signs the app with Developer ID
#   3. Creates a ZIP of the signed .app (for Sparkle updates)
#   4. Builds the DMG (for direct distribution)
#   5. Generates/updates the Sparkle appcast with EdDSA signature
#   6. Creates a GitHub Release and uploads the DMG
#   7. Commits and pushes the updated appcast
#
# Prerequisites:
#   - gh (GitHub CLI) installed and authenticated
#   - Sparkle EdDSA private key in Keychain (run generate_keys once)
#   - Developer ID certificate in Keychain

set -e

if [ -z "$1" ]; then
    echo "Usage: ./release.sh <version>"
    echo "Example: ./release.sh 1.1"
    exit 1
fi

VERSION="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="HushType"
SIGN_IDENTITY="Developer ID Application: Malcolm Taylor (98MYPLP7G2)"

echo ""
echo "========================================="
echo "  Releasing $APP_NAME $VERSION"
echo "========================================="
echo ""

# Step 1: Update version in Info.plist
echo "=== Step 1: Updating version to $VERSION ==="
INFO_PLIST="$SCRIPT_DIR/Sources/HushType/Resources/Info.plist"
# Update CFBundleShortVersionString
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
# Update CFBundleVersion (use version without dots for build number, or increment)
BUILD_NUM=$(echo "$VERSION" | tr -d '.')
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUM" "$INFO_PLIST"
echo "  CFBundleShortVersionString = $VERSION"
echo "  CFBundleVersion = $BUILD_NUM"

# Step 2: Build and create DMG with Developer ID signing
echo ""
echo "=== Step 2: Building and signing ==="
"$SCRIPT_DIR/build-dmg.sh" --sign "$SIGN_IDENTITY"

# Step 3: Create a ZIP of the .app for Sparkle updates
echo ""
echo "=== Step 3: Creating update ZIP ==="
ZIP_NAME="$APP_NAME-$VERSION.zip"
cd "$SCRIPT_DIR"
ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$ZIP_NAME"
ZIP_SIZE=$(stat -f%z "$ZIP_NAME")
echo "  Created: $ZIP_NAME ($ZIP_SIZE bytes)"

# Step 4: Notarise the DMG
echo ""
echo "=== Step 4: Notarising DMG ==="
echo "  Submitting to Apple..."
xcrun notarytool submit "$APP_NAME.dmg" --keychain-profile "$APP_NAME" --wait
echo "  Stapling..."
xcrun stapler staple "$APP_NAME.dmg"

# Step 5: Generate appcast entry
echo ""
echo "=== Step 5: Generating appcast ==="
# The generate_appcast tool should be available after building Sparkle from SPM
# or from a downloaded Sparkle release. Adjust the path as needed.
GENERATE_APPCAST=""
for candidate in \
    "$SCRIPT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_appcast" \
    "$HOME/.local/bin/generate_appcast" \
    "/usr/local/bin/generate_appcast"; do
    if [ -x "$candidate" ]; then
        GENERATE_APPCAST="$candidate"
        break
    fi
done

if [ -n "$GENERATE_APPCAST" ]; then
    # Create a staging directory with the ZIP for generate_appcast
    APPCAST_DIR=$(mktemp -d)
    cp "$ZIP_NAME" "$APPCAST_DIR/"
    if [ -f "$SCRIPT_DIR/docs/appcast.xml" ]; then
        cp "$SCRIPT_DIR/docs/appcast.xml" "$APPCAST_DIR/"
    fi

    # Point download URLs at GitHub Releases (not GitHub Pages)
    DOWNLOAD_PREFIX="https://github.com/malcolmct/HushType/releases/download/v$VERSION/"
    "$GENERATE_APPCAST" --download-url-prefix "$DOWNLOAD_PREFIX" "$APPCAST_DIR"

    cp "$APPCAST_DIR/appcast.xml" "$SCRIPT_DIR/docs/appcast.xml"
    rm -rf "$APPCAST_DIR"
    echo "  Updated docs/appcast.xml"
else
    echo "  WARNING: generate_appcast not found."
    echo "  You'll need to update docs/appcast.xml manually."
    echo "  Download Sparkle from https://github.com/sparkle-project/Sparkle/releases"
    echo "  and run: ./bin/generate_appcast <folder-with-zip>"
fi

# Step 6: Create GitHub Release
echo ""
echo "=== Step 6: Creating GitHub Release ==="
gh release create "v$VERSION" "$APP_NAME.dmg" "$ZIP_NAME" \
    --title "$APP_NAME $VERSION" \
    --generate-notes

# Step 7: Commit and push
echo ""
echo "=== Step 7: Committing changes ==="
cd "$SCRIPT_DIR"
git add docs/appcast.xml Sources/HushType/Resources/Info.plist
git commit -m "Release $VERSION"
git push origin main

echo ""
echo "========================================="
echo "  Release $VERSION complete!"
echo "========================================="
echo ""
echo "  DMG:     $APP_NAME.dmg"
echo "  ZIP:     $ZIP_NAME"
echo "  Appcast: docs/appcast.xml"
echo "  GitHub:  https://github.com/malcolmct/HushType/releases/tag/v$VERSION"
echo ""
