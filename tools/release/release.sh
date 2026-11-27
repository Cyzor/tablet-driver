#!/usr/bin/env bash
# MockTab build pipeline: archive → export → DMG → notarize → staple.
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
# Usage: tools/release/release.sh [--snapshot]
#   Reads MARKETING_VERSION from the project; produces dist/MockTab-<ver>.dmg.
#   --snapshot builds the rolling pre-release from the current commit instead:
#   dist/MockTab-snapshot.dmg, plus dist/MockTab-snapshot.stamp, the app's UTC
#   build stamp for the snapshot tag message.

set -euo pipefail

# Repo root is two levels up: this script lives in tools/release/.
cd "$(dirname "$0")/../.."

SCHEME="MockTab"
PROJECT="MockTab.xcodeproj"
CONFIG="Release"
KEYCHAIN_PROFILE="MockTabNotary"
EXPORT_OPTIONS="tools/release/ExportOptions.plist"

# Notary auth: the stored keychain profile (MockTabNotary), unless
# NOTARY_APPLE_ID, NOTARY_PASSWORD (app-specific), and NOTARY_TEAM_ID are set.
if [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_PASSWORD:-}" && -n "${NOTARY_TEAM_ID:-}" ]]; then
    NOTARY_AUTH=(--apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$NOTARY_TEAM_ID")
else
    NOTARY_AUTH=(--keychain-profile "$KEYCHAIN_PROFILE")
fi

DIST_DIR="dist"
BUILD_DIR="$DIST_DIR/build"

if [[ "${1:-}" == "--snapshot" ]]; then
    NAME="snapshot"
    TITLE="MockTab snapshot ($(git rev-parse --short HEAD))"
    RELEASE_SETTING=()
else
    NAME=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
        -showBuildSettings 2>/dev/null | awk '/ MARKETING_VERSION = /{print $3; exit}')
    if [[ -z "$NAME" ]]; then
        echo "error: could not read MARKETING_VERSION" >&2
        exit 1
    fi
    TITLE="MockTab $NAME"
    RELEASE_SETTING=(MOCKTAB_RELEASE=YES)
fi

ARCHIVE="$BUILD_DIR/MockTab-$NAME.xcarchive"
EXPORT_PATH="$BUILD_DIR/export-$NAME"
DMG_PATH="$DIST_DIR/MockTab-$NAME.dmg"
STAMP_PATH="$DIST_DIR/MockTab-snapshot.stamp"

rm -rf "$BUILD_DIR" "$DMG_PATH" "$STAMP_PATH"
mkdir -p "$BUILD_DIR"

echo "==> Archiving $TITLE"
BEAUTIFY=cat
command -v xcbeautify >/dev/null 2>&1 && BEAUTIFY=xcbeautify
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
    -archivePath "$ARCHIVE" \
    -destination "generic/platform=macOS" \
    ${RELEASE_SETTING[@]+"${RELEASE_SETTING[@]}"} \
    archive | $BEAUTIFY

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

SHIPPED_LANGUAGES=$(find "$APP_PATH/Contents/Resources" -maxdepth 1 -name "*.lproj" -exec basename {} .lproj \; | sort | tr '\n' ' ')
# Every language in the source ships; a missing one means a broken build.
if [[ "$SHIPPED_LANGUAGES" != "de en es fr it ja " ]]; then
    echo "error: expected languages de en es fr it ja, found: $SHIPPED_LANGUAGES" >&2
    exit 1
fi
codesign --verify --deep --strict "$APP_PATH"

tools/release/size-watch.sh "$APP_PATH" || echo "size-watch: check failed; continuing (it only warns)"
tools/release/arch-check.sh "$APP_PATH"
if [[ "$NAME" == "snapshot" ]]; then
    tools/release/bundle-check.sh "$APP_PATH"
else
    tools/release/bundle-check.sh --release "$APP_PATH"
fi

# The update page matches a snapshot on this stamp.
if [[ "$NAME" == "snapshot" ]]; then
    /usr/libexec/PlistBuddy -c "Print :MockTabBuildStamp" "$APP_PATH/Contents/Info.plist" >"$STAMP_PATH"
fi

echo "==> Notarizing .app"
# Notarize and staple the .app *before* packaging it. A ticket stapled to
# the .app travels with it when users drag it out of the DMG, so first-launch
# Gatekeeper checks succeed even offline. Stapling only the DMG would leave
# the extracted .app dependent on an online check against Apple's CDN.
# Fails with Apple's reasons when the verdict isn't Accepted; notarytool
# can exit 0 on a rejection.
notarize() {
    local result id status
    result=$(xcrun notarytool submit "$1" "${NOTARY_AUTH[@]}" --wait --output-format json)
    id=$(plutil -extract id raw -o - - <<<"$result")
    status=$(plutil -extract status raw -o - - <<<"$result")
    echo "notarytool: $status ($id)"
    if [[ "$status" != "Accepted" ]]; then
        xcrun notarytool log "$id" "${NOTARY_AUTH[@]}" >&2 || true
        echo "error: notarization of $1 came back $status" >&2
        exit 1
    fi
}

APP_ZIP="$BUILD_DIR/MockTab-$NAME.zip"
ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
notarize "$APP_ZIP"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose "$APP_PATH"

echo "==> Building DMG"
source tools/release/dmgbuild.sh
"$DMGBUILD" -s tools/release/dmg_settings.py -D app="$APP_PATH" \
    -D background=tools/release/dmg_background.png \
    "$TITLE" "$DMG_PATH"

# Gatekeeper rejects an unsigned DMG even when it's notarized and stapled.
# Sign it with the identity that signed the app.
IDENTITY=$(codesign -dvv "$APP_PATH" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)/\1/p' | head -1)
[[ -n "$IDENTITY" ]] || { echo "error: no Developer ID identity on $APP_PATH" >&2; exit 1; }
codesign --sign "$IDENTITY" --timestamp "$DMG_PATH"

echo "==> Notarizing DMG"
notarize "$DMG_PATH"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH"

echo
echo "Done: $DMG_PATH"
