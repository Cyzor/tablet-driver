#!/usr/bin/env bash
# MockTab — full release pipeline (build → notarize → DMG → tag → draft release).
#
# Wraps tools/release/release.sh with the surrounding git + GitHub work so the entire
# release can be triggered as one action (from Xcode's "Release" aggregate target
# or directly from the terminal).
#
# This script is the release path. With --snapshot it builds the rolling
# pre-release instead: it adds the new image to the one snapshot release
# beside the last, so the live feed's link keeps working, force-moves the
# "snapshot" tag to HEAD, and prints the command that moves the feed on.
# From any branch. SNAPSHOT_NOTES=<file>, relative
# to the repo root, ends the release body with that file's text as one line:
# the notes the app shows, items separated by "; ".
#
# Flow:
#   1. Sanity: clean working tree, on main, gh installed and authenticated.
#   2. Read MARKETING_VERSION; verify tag v<version> doesn't exist yet.
#   3. Run tools/release/release.sh (archive → export → DMG → notarize → staple).
#   4. gh release create --draft with the DMG attached.
#   5. Tag HEAD and push the tag.
#   6. Open the draft release in the browser.
#
# A numbered release is a draft; nothing is public until you click Publish on
# GitHub. It takes notes from release-notes/v<version>.md if present, else
# GitHub generates them from commits since the previous tag.
#
# Pre-flight to add a new release:
#   1. Bump MARKETING_VERSION in MockTab.xcodeproj.
#   2. (Optional) Create release-notes/v<new-version>.md.
#   3. Turn CHANGELOG.md's Unreleased line into the new version's line.
#   4. Commit and push.
#   5. Run this script (or build the "Release" scheme in Xcode).

set -euo pipefail

SNAPSHOT=0
[[ "${1:-}" == "--snapshot" ]] && SNAPSHOT=1

# Xcode's Run Script phase strips PATH down to system minimums.
# Restore homebrew so xcodebuild can find gh, xcrun finds notarytool, etc.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Repo root is two levels up: this script lives in tools/release/.
cd "$(dirname "$0")/../.."

# ─── 1. Sanity checks ─────────────────────────────────────────────────────────

if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: working tree has uncommitted changes. Commit or stash first." >&2
    git status --short >&2
    exit 1
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD)
if (( ! SNAPSHOT )) && [[ "$BRANCH" != "main" ]]; then
    echo "error: not on main (currently on '$BRANCH'). Release tags only ship from main." >&2
    exit 1
fi

if ! command -v gh >/dev/null; then
    echo "error: gh CLI not installed (brew install gh)" >&2
    exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
    echo "error: gh CLI not authenticated (gh auth login)" >&2
    exit 1
fi

if (( SNAPSHOT )); then
    SHA_SHORT=$(git rev-parse --short HEAD)
    echo "==> Snapshotting MockTab ($SHA_SHORT)"
    tools/release/release.sh --snapshot
    DMG_PATH="dist/MockTab-snapshot.dmg"
    [[ -f "$DMG_PATH" ]] || { echo "error: expected $DMG_PATH after tools/release/release.sh" >&2; exit 1; }

    # Each build gets its own file name, added beside the last one, so the
    # link the live feed holds keeps serving the file its checksum matches
    # until the feed moves on.
    STAMP=$(cat dist/MockTab-snapshot.stamp)
    ASSET="dist/MockTab-snapshot-$STAMP.dmg"
    cp "$DMG_PATH" "$ASSET"

    # update-latest.sh takes the body's last line as the notes; without
    # notes, it uses CHANGELOG.md's Unreleased line.
    BUILT_AT=$(date -u +'%Y-%m-%d %H:%M UTC')
    NOTES_FILE=${SNAPSHOT_NOTES:-}
    NOTES_LINE=""
    if [[ -n "$NOTES_FILE" && -s "$NOTES_FILE" ]]; then
        NOTES_LINE="

$(grep -v '^[[:space:]]*$' "$NOTES_FILE" | tr '\n' ' ' | sed -E 's/ +$//')"
    fi
    BODY="Rolling pre-release build of next, replaced on each snapshot run — not a numbered version.

Commit: ${SHA_SHORT}
Built: ${BUILT_AT}${NOTES_LINE}"

    if gh release view snapshot &>/dev/null; then
        # Keep only the newest image, the one the feed points at, then add
        # this one beside it.
        OLD=$(gh release view snapshot --json assets \
            --jq '[.assets[] | select(.name | endswith(".dmg"))] | sort_by(.createdAt) | .[:-1][] | .name')
        while IFS= read -r name; do
            [[ -n "$name" ]] && gh release delete-asset snapshot "$name" --yes
        done <<<"$OLD"
        echo "==> Adding $ASSET to the snapshot pre-release"
        gh release upload snapshot "$ASSET"
    else
        echo "==> Creating the snapshot pre-release"
        gh release create snapshot "$ASSET" --title "MockTab snapshot" --prerelease \
            --notes "$BODY"
    fi

    # The feed reads the build stamp from the tag, so it moves with the image.
    echo "==> Moving the snapshot tag to $SHA_SHORT"
    git tag -f -a snapshot -m "$STAMP" HEAD
    git push origin snapshot --force
    gh release edit snapshot --notes "$BODY"

    echo "==> Opening the release"
    gh release view snapshot --web
    echo
    echo "Done. Edit the notes on GitHub if needed, then update the feed:"
    echo "  gh workflow run update-latest.yml -f tag=snapshot"
    exit 0
fi

# ─── 2. Resolve version and tag ───────────────────────────────────────────────

SCHEME="MockTab"
PROJECT="MockTab.xcodeproj"
CONFIG="Release"

VERSION=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
    -showBuildSettings 2>/dev/null | awk '/ MARKETING_VERSION = /{print $3; exit}')
if [[ -z "$VERSION" ]]; then
    echo "error: could not read MARKETING_VERSION from $PROJECT" >&2
    exit 1
fi
TAG="v$VERSION"

if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "error: tag $TAG already exists locally. Bump MARKETING_VERSION before releasing." >&2
    exit 1
fi
if git ls-remote --tags origin 2>/dev/null | grep -q "refs/tags/$TAG\$"; then
    echo "error: tag $TAG already exists on origin. Bump MARKETING_VERSION before releasing." >&2
    exit 1
fi

echo "==> Releasing MockTab $VERSION (tag $TAG)"

# ─── 3. Build, sign, notarize, package ────────────────────────────────────────

tools/release/release.sh

DMG_PATH="dist/MockTab-$VERSION.dmg"
if [[ ! -f "$DMG_PATH" ]]; then
    echo "error: expected $DMG_PATH after tools/release/release.sh" >&2
    exit 1
fi

# ─── 4. Create draft GitHub release ───────────────────────────────────────────

# The draft comes first: a failed upload then leaves no tag behind to block
# a rerun. A draft makes no tag of its own; the one pushed below is the one
# Publish uses.
echo "==> Creating draft GitHub release"
TARGET=$(git rev-parse HEAD)
NOTES_FILE="release-notes/$TAG.md"
if [[ -f "$NOTES_FILE" ]]; then
    gh release create "$TAG" "$DMG_PATH" \
        --title "MockTab $VERSION" \
        --notes-file "$NOTES_FILE" \
        --target "$TARGET" \
        --draft
else
    gh release create "$TAG" "$DMG_PATH" \
        --title "MockTab $VERSION" \
        --generate-notes \
        --target "$TARGET" \
        --draft
fi

# ─── 5. Tag and push ──────────────────────────────────────────────────────────

echo "==> Tagging $TAG"
git tag -a "$TAG" -m "Release $VERSION"
git push origin "$TAG"

# ─── 6. Open the draft for review ─────────────────────────────────────────────

echo "==> Opening draft release"
gh release view "$TAG" --web

echo
echo "Done. Review the draft on GitHub and click Publish when ready."
