#!/usr/bin/env bash
# MockTab — full release pipeline (build → notarize → DMG → tag → draft release).
#
# Wraps tools/release/release.sh with the surrounding git + GitHub work so the entire
# release can be triggered as one action (from Xcode's "Release" aggregate target
# or directly from the terminal).
#
# NOTE: .github/workflows/release.yml does the same thing in CI when you push a
# v* tag. Use ONE path per release. This script pushes the tag in step 4, which
# will also fire that workflow; its run is expected to error on "create release"
# (the draft already exists here). For a pure CI release, just push a tag and
# skip this script. Prefer this script only when releasing offline/by hand.
#
# Flow:
#   1. Sanity: clean working tree, on main, gh installed and authenticated.
#   2. Read MARKETING_VERSION; verify tag v<version> doesn't exist yet.
#   3. Run tools/release/release.sh (archive → export → DMG → notarize → staple).
#   4. Tag HEAD and push the tag.
#   5. gh release create --draft with the DMG attached.
#   6. Open the draft release in the browser.
#
# The release is created as a DRAFT — nothing is public until you click Publish
# on GitHub. Notes are read from release-notes/v<version>.md if present, else
# auto-generated from commits since the previous tag via --generate-notes.
#
# Pre-flight to add a new release:
#   1. Bump MARKETING_VERSION in MockTab.xcodeproj.
#   2. (Optional) Create release-notes/v<new-version>.md.
#   3. Add a line for the new version to CHANGELOG.md.
#   4. Commit and push.
#   5. Run this script (or build the "Release" scheme in Xcode).

set -euo pipefail

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
if [[ "$BRANCH" != "main" ]]; then
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

# ─── 4. Tag and push ──────────────────────────────────────────────────────────

echo "==> Tagging $TAG"
git tag -a "$TAG" -m "Release $VERSION"
git push origin "$TAG"

# ─── 5. Create draft GitHub release ───────────────────────────────────────────

echo "==> Creating draft GitHub release"
NOTES_FILE="release-notes/$TAG.md"
if [[ -f "$NOTES_FILE" ]]; then
    gh release create "$TAG" "$DMG_PATH" \
        --title "MockTab $VERSION" \
        --notes-file "$NOTES_FILE" \
        --draft
else
    gh release create "$TAG" "$DMG_PATH" \
        --title "MockTab $VERSION" \
        --generate-notes \
        --draft
fi

# ─── 6. Open the draft for review ─────────────────────────────────────────────

echo "==> Opening draft release"
gh release view "$TAG" --web

echo
echo "Done. Review the draft on GitHub and click Publish when ready."
