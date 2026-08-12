#!/usr/bin/env bash
# MockTab release pipeline: archive → export → DMG → notarize → staple.
#
# Prerequisites (one-time):
#   1. Developer ID Application certificate installed in login keychain.
#   2. Notary credentials stored:
#        xcrun notarytool store-credentials MockTabNotary \
#          --apple-id you@example.com \
#          --team-id 3R62GZR6Q2 \
#          --password <app-specific-password>
#   3. Xcode build setting ENABLE_HARDENED_RUNTIME = YES on the MockTab target.
#
# Usage: tools/release.sh
#   Reads MARKETING_VERSION from the project; produces dist/MockTab-<ver>.dmg.

set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="MockTab"
PROJECT="MockTab.xcodeproj"
CONFIG="Release"
KEYCHAIN_PROFILE="MockTabNotary"
EXPORT_OPTIONS="tools/release/ExportOptions.plist"

# Notary auth. Locally we use the stored keychain profile (MockTabNotary).
# CI has no login keychain, so it passes credentials via the environment:
# set NOTARY_APPLE_ID, NOTARY_PASSWORD (app-specific), and NOTARY_TEAM_ID.
if [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_PASSWORD:-}" && -n "${NOTARY_TEAM_ID:-}" ]]; then
    NOTARY_AUTH=(--apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$NOTARY_TEAM_ID")
else
    NOTARY_AUTH=(--keychain-profile "$KEYCHAIN_PROFILE")
fi

DIST_DIR="dist"
BUILD_DIR="$DIST_DIR/build"

VERSION=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
    -showBuildSettings 2>/dev/null | awk '/ MARKETING_VERSION = /{print $3; exit}')
if [[ -z "$VERSION" ]]; then
    echo "error: could not read MARKETING_VERSION" >&2
    exit 1
fi

ARCHIVE="$BUILD_DIR/MockTab-$VERSION.xcarchive"
EXPORT_PATH="$BUILD_DIR/export-$VERSION"
DMG_STAGING="$BUILD_DIR/dmg-$VERSION"
DMG_PATH="$DIST_DIR/MockTab-$VERSION.dmg"

rm -rf "$BUILD_DIR" "$DMG_PATH"
mkdir -p "$BUILD_DIR"

echo "==> Archiving $SCHEME $VERSION"
if command -v xcbeautify >/dev/null 2>&1; then
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
        -archivePath "$ARCHIVE" \
        -destination "generic/platform=macOS" \
        archive | xcbeautify
else
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
        -archivePath "$ARCHIVE" \
        -destination "generic/platform=macOS" \
        archive
fi

echo "==> Exporting signed .app"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS"

APP_PATH="$EXPORT_PATH/MockTab.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "error: expected $APP_PATH after export" >&2
    exit 1
fi

echo "==> Notarizing .app"
# Notarize and staple the .app *before* packaging it. A ticket stapled to
# the .app travels with it when users drag it out of the DMG, so first-launch
# Gatekeeper checks succeed even offline. Stapling only the DMG would leave
# the extracted .app dependent on an online check against Apple's CDN.
APP_ZIP="$BUILD_DIR/MockTab-$VERSION.zip"
ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" \
    "${NOTARY_AUTH[@]}" \
    --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo "==> Building DMG"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create -volname "MockTab $VERSION" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDZO \
    "$DMG_PATH"

echo "==> Notarizing DMG"
xcrun notarytool submit "$DMG_PATH" \
    "${NOTARY_AUTH[@]}" \
    --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

echo
echo "Done: $DMG_PATH"
echo "Next: gh release create v$VERSION \"$DMG_PATH\" --notes-file notes.md"
