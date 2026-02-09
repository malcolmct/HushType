#!/bin/bash
# Release a new version of HushType.
#
# Usage:
#   ./release.sh <version>
#
# Example:
#   ./release.sh 1.5
#
# What it does:
#   1. Updates the version in Info.plist
#   2. Builds the app and signs with Developer ID
#   3. Creates the DMG from the signed app
#   4. Notarises the DMG (which notarises all binaries inside it)
#   5. Staples the notarisation ticket to both the .app and the DMG
#   6. Creates a ZIP of the stapled .app (for Sparkle updates)
#   7. Generates/updates the Sparkle appcast with EdDSA signature
#   8. Creates a GitHub Release and uploads the DMG + ZIP
#   9. Commits and pushes the updated appcast
#
# Prerequisites:
#   - gh (GitHub CLI) installed and authenticated
#   - Sparkle EdDSA private key in Keychain (run generate_keys once)
#   - Developer ID certificate in Keychain
#   - Notarytool keychain profile stored as "HushType"
#     (xcrun notarytool store-credentials "HushType" ...)

set -e

if [ -z "$1" ]; then
    echo "Usage: ./release.sh <version>"
    echo "Example: ./release.sh 1.5"
    exit 1
fi

VERSION="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="HushType"
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"
SIGN_IDENTITY="Developer ID Application: Malcolm Taylor (98MYPLP7G2)"
ENTITLEMENTS="$SCRIPT_DIR/HushType-distribution.entitlements"

echo ""
echo "========================================="
echo "  Releasing $APP_NAME $VERSION"
echo "========================================="
echo ""

# Pre-flight: check for uncommitted changes
DIRTY_FILES=$(cd "$SCRIPT_DIR" && git status --porcelain 2>/dev/null | grep -v '^\?\?' | grep -v 'Info.plist' || true)
if [ -n "$DIRTY_FILES" ]; then
    echo "⚠  You have uncommitted changes:"
    echo ""
    echo "$DIRTY_FILES" | sed 's/^/   /'
    echo ""
    read -p "These won't be included in the release. Continue anyway? [y/N] " REPLY
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        echo "Aborting. Commit your changes first, then re-run ./release.sh $VERSION"
        exit 1
    fi
    echo ""
fi

# Step 1: Update version in Info.plist and User Guide
echo "=== Step 1: Updating version to $VERSION ==="
INFO_PLIST="$SCRIPT_DIR/Sources/HushType/Resources/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
BUILD_NUM=$(echo "$VERSION" | tr -d '.')
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUM" "$INFO_PLIST"
echo "  CFBundleShortVersionString = $VERSION"
echo "  CFBundleVersion = $BUILD_NUM"

# Update the User Guide version and regenerate the docx
GUIDE_SCRIPT="$SCRIPT_DIR/create-guide.js"
GUIDE_DOCX="$SCRIPT_DIR/HushType-User-Guide.docx"
GUIDE_PDF="$SCRIPT_DIR/HushType-User-Guide.pdf"
if [ -f "$GUIDE_SCRIPT" ] && command -v node >/dev/null 2>&1; then
    # Replace the version string in create-guide.js (matches: "Version X.Y" or "Version X.Y.Z")
    sed -i '' "s/\"Version [0-9][0-9.]*\"/\"Version $VERSION\"/" "$GUIDE_SCRIPT"
    echo "  User Guide version updated to $VERSION"
    (cd "$SCRIPT_DIR" && node create-guide.js)
    echo "  Regenerated HushType-User-Guide.docx"

    # Convert the docx to PDF for DMG inclusion
    # On macOS, LibreOffice lives inside /Applications and isn't on the PATH
    SOFFICE=""
    if command -v soffice >/dev/null 2>&1; then
        SOFFICE="soffice"
    elif [ -x "/Applications/LibreOffice.app/Contents/MacOS/soffice" ]; then
        SOFFICE="/Applications/LibreOffice.app/Contents/MacOS/soffice"
    fi

    if [ -n "$SOFFICE" ]; then
        echo "  Converting User Guide to PDF (LibreOffice: $SOFFICE)..."
        "$SOFFICE" --headless --convert-to pdf --outdir "$SCRIPT_DIR" "$GUIDE_DOCX" 2>&1 | sed 's/^/    /'
    elif command -v pandoc >/dev/null 2>&1; then
        echo "  Converting User Guide to PDF (pandoc)..."
        pandoc "$GUIDE_DOCX" -o "$GUIDE_PDF" 2>&1 | sed 's/^/    /'
    fi

    # Verify the PDF was created
    if [ -f "$GUIDE_PDF" ]; then
        echo "  User Guide PDF created successfully"
    else
        echo "  WARNING: PDF conversion failed. The DMG will include the .docx version."
        echo "  To fix: ensure LibreOffice is installed and not running, then retry."
        echo "  Manual conversion: /Applications/LibreOffice.app/Contents/MacOS/soffice --headless --convert-to pdf --outdir . HushType-User-Guide.docx"
    fi
elif [ -f "$GUIDE_SCRIPT" ]; then
    echo "  WARNING: node not found — skipping User Guide regeneration."
    echo "  Run 'node create-guide.js' manually before distributing."
fi

# Step 2: Build the app and sign with Developer ID
echo ""
echo "=== Step 2: Building and signing ==="
"$SCRIPT_DIR/build-app.sh"

# Sign with Developer ID (inside-out order for Sparkle.framework)
SIGN_DIR=$(mktemp -d)
SIGN_BUNDLE="$SIGN_DIR/$APP_NAME.app"
echo "  Copying to $SIGN_DIR (outside iCloud)…"
ditto --norsrc --noextattr --noqtn "$APP_BUNDLE" "$SIGN_BUNDLE"

if [ -d "$SIGN_BUNDLE/Contents/Frameworks/Sparkle.framework" ]; then
    echo "  Signing Sparkle.framework (inside-out)..."
    find "$SIGN_BUNDLE/Contents/Frameworks/Sparkle.framework" -name "*.xpc" -type d | while read xpc; do
        codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$xpc"
    done
    find "$SIGN_BUNDLE/Contents/Frameworks/Sparkle.framework" \( -name "Autoupdate" -o -name "Updater" -o -name "Installer" \) | while read helper; do
        if [ -f "$helper" ] && file "$helper" | grep -q "Mach-O"; then
            codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$helper"
        fi
    done
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$SIGN_BUNDLE/Contents/Frameworks/Sparkle.framework"
fi

codesign --force --sign "$SIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    --options runtime \
    --timestamp \
    "$SIGN_BUNDLE"

rm -rf "$APP_BUNDLE"
mv "$SIGN_BUNDLE" "$APP_BUNDLE"
rm -rf "$SIGN_DIR"
echo "  Signed with: $SIGN_IDENTITY"

# Step 3: Create the DMG from the signed app
echo ""
echo "=== Step 3: Creating DMG ==="
# Use --skip-build since we already have the signed app; do NOT pass --sign
# because that would re-sign the app (we already signed it above).
"$SCRIPT_DIR/build-dmg.sh" --skip-build
# Sign just the DMG file itself (this doesn't touch the app inside)
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$APP_NAME.dmg"

# Step 4: Notarise the DMG (this notarises everything inside it too)
echo ""
echo "=== Step 4: Notarising ==="
echo "  Submitting DMG to Apple..."
xcrun notarytool submit "$APP_NAME.dmg" --keychain-profile "$APP_NAME" --wait

# Step 5: Staple notarisation tickets
echo ""
echo "=== Step 5: Stapling ==="
echo "  Stapling app bundle..."
xcrun stapler staple "$APP_BUNDLE"
echo "  Stapling DMG..."
xcrun stapler staple "$APP_NAME.dmg"
echo "  Both app and DMG are notarised and stapled."

# Step 6: Create the Sparkle update ZIP (from the stapled app)
echo ""
echo "=== Step 6: Creating update ZIP ==="
ZIP_NAME="$APP_NAME-$VERSION.zip"
cd "$SCRIPT_DIR"
ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$ZIP_NAME"
ZIP_SIZE=$(stat -f%z "$ZIP_NAME")
echo "  Created: $ZIP_NAME ($ZIP_SIZE bytes)"

# Step 7: Generate appcast entry
echo ""
echo "=== Step 7: Generating appcast ==="
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
    APPCAST_DIR=$(mktemp -d)
    cp "$ZIP_NAME" "$APPCAST_DIR/"
    if [ -f "$SCRIPT_DIR/docs/appcast.xml" ]; then
        cp "$SCRIPT_DIR/docs/appcast.xml" "$APPCAST_DIR/"
    fi

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

# Step 8: Create GitHub Release
echo ""
echo "=== Step 8: Creating GitHub Release ==="
gh release create "v$VERSION" \
    --title "$APP_NAME $VERSION" \
    --generate-notes

# Upload assets with progress bars via curl (gh doesn't show progress)
GH_TOKEN=$(gh auth token)
REPO="malcolmct/HushType"
UPLOAD_BASE="https://uploads.github.com/repos/$REPO/releases"
RELEASE_ID=$(gh api "repos/$REPO/releases/tags/v$VERSION" --jq '.id')

for ASSET in "$APP_NAME.dmg" "$ZIP_NAME"; do
    ASSET_SIZE=$(stat -f%z "$ASSET")
    ASSET_MB=$(echo "scale=1; $ASSET_SIZE / 1048576" | bc)
    echo "  Uploading $ASSET (${ASSET_MB} MB)..."
    curl --progress-bar \
        -H "Authorization: token $GH_TOKEN" \
        -H "Content-Type: application/octet-stream" \
        --data-binary @"$ASSET" \
        "$UPLOAD_BASE/$RELEASE_ID/assets?name=$(basename "$ASSET")" \
        -o /dev/null
    echo "  $ASSET uploaded"
done

# Step 9: Commit and push
echo ""
echo "=== Step 9: Committing changes ==="
cd "$SCRIPT_DIR"
git add docs/appcast.xml Sources/HushType/Resources/Info.plist
git add create-guide.js HushType-User-Guide.docx HushType-User-Guide.pdf 2>/dev/null || true
git add CLAUDE.md 2>/dev/null || true
git commit -m "Release $VERSION"
git push origin main

echo ""
echo "========================================="
echo "  Release $VERSION complete!"
echo "========================================="
echo ""
echo "  DMG:     $APP_NAME.dmg (notarised + stapled)"
echo "  ZIP:     $ZIP_NAME (notarised + stapled app inside)"
echo "  Appcast: docs/appcast.xml"
echo "  GitHub:  https://github.com/malcolmct/HushType/releases/tag/v$VERSION"
echo ""
