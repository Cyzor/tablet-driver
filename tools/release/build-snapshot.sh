#!/usr/bin/env bash
# MockTab snapshot pipeline: archive → export → DMG → notarize → staple.
#
# Builds an unversioned, notarized pre-release DMG from the current commit on
# main. Unlike tools/release/release.sh, this does NOT read or require a bumped
# MARKETING_VERSION — it always produces dist/MockTab-snapshot.dmg, identified
# by commit SHA rather than a version number. Intended to be replaced wholesale
# by the next snapshot build, not archived alongside older ones.
#
# Prerequisites: same as tools/release/release.sh (Developer ID cert, notary
# credentials under the MockTabNotary keychain profile or NOTARY_* env vars,
# ENABLE_HARDENED_RUNTIME = YES).
#
# Usage: tools/release/build-snapshot.sh
#   Produces dist/MockTab-snapshot.dmg.

set -euo pipefail

# Repo root is two levels up: this script lives in tools/release/.
cd "$(dirname "$0")/../.."

SCHEME="MockTab"
PROJECT="MockTab.xcodeproj"
CONFIG="Release"
KEYCHAIN_PROFILE="MockTabNotary"
EXPORT_OPTIONS="tools/release/ExportOptions.plist"

if [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_PASSWORD:-}" && -n "${NOTARY_TEAM_ID:-}" ]]; then
    NOTARY_AUTH=(--apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$NOTARY_TEAM_ID")
else
    NOTARY_AUTH=(--keychain-profile "$KEYCHAIN_PROFILE")
fi

DIST_DIR="dist"
BUILD_DIR="$DIST_DIR/build"
SHA_SHORT=$(git rev-parse --short HEAD)

ARCHIVE="$BUILD_DIR/MockTab-snapshot.xcarchive"
EXPORT_PATH="$BUILD_DIR/export-snapshot"
DMG_STAGING="$BUILD_DIR/dmg-snapshot"
DMG_PATH="$DIST_DIR/MockTab-snapshot.dmg"

rm -rf "$BUILD_DIR" "$DMG_PATH"
mkdir -p "$BUILD_DIR"

echo "==> Archiving $SCHEME snapshot ($SHA_SHORT)"
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
APP_ZIP="$BUILD_DIR/MockTab-snapshot.zip"
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
hdiutil create -volname "MockTab snapshot ($SHA_SHORT)" \
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
echo "Done: $DMG_PATH ($SHA_SHORT)"
