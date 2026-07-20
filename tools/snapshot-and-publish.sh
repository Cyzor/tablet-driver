#!/usr/bin/env bash
# MockTab — full snapshot pipeline (build → notarize → DMG → tag → draft pre-release).
#
# Wraps tools/build-snapshot.sh with the surrounding git + GitHub work, mirroring
# tools/release-and-publish.sh but for the rolling "snapshot" pre-release instead
# of a numbered version. Lets you publish "here's roughly where main stands"
# offline/by hand without touching the Actions tab.
#
# NOTE: .github/workflows/snapshot.yml does the same thing in CI when you
# manually dispatch it. Use ONE path per snapshot. Prefer this script when
# you want to build and review locally before anything reaches GitHub at all.
#
# Flow:
#   1. Sanity: clean working tree, gh installed and authenticated.
#   2. Run tools/build-snapshot.sh (archive → export → DMG → notarize → staple).
#   3. Force-move the "snapshot" tag to HEAD and push it.
#   4. Delete any existing "snapshot" release, then gh release create --draft
#      with the DMG attached. There is only ever one snapshot at a time — no
#      history of past snapshots is kept.
#   5. Open the draft release in the browser.
#
# The release is created as a DRAFT — nothing is public until you click
# Publish on GitHub.

set -euo pipefail

# Xcode's Run Script phase strips PATH down to system minimums.
# Restore homebrew so xcodebuild can find gh, xcrun finds notarytool, etc.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

cd "$(dirname "$0")/.."

# ─── 1. Sanity checks ─────────────────────────────────────────────────────────

if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: working tree has uncommitted changes. Commit or stash first." >&2
    git status --short >&2
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

SHA_SHORT=$(git rev-parse --short HEAD)
echo "==> Snapshotting MockTab ($SHA_SHORT)"

# ─── 2. Build, sign, notarize, package ────────────────────────────────────────

tools/build-snapshot.sh

DMG_PATH="dist/MockTab-snapshot.dmg"
if [[ ! -f "$DMG_PATH" ]]; then
    echo "error: expected $DMG_PATH after tools/build-snapshot.sh" >&2
    exit 1
fi

# ─── 3. Move the snapshot tag and push ────────────────────────────────────────

echo "==> Moving the snapshot tag to $SHA_SHORT"
git tag -f snapshot HEAD
git push origin snapshot --force

# ─── 4. Replace the draft snapshot pre-release ────────────────────────────────

echo "==> Replacing the snapshot pre-release (draft)"
BUILT_AT=$(date -u +'%Y-%m-%d %H:%M UTC')
if gh release view snapshot &>/dev/null; then
    gh release delete snapshot --yes
fi
gh release create snapshot "$DMG_PATH" \
    --title "MockTab snapshot" \
    --prerelease \
    --draft \
    --notes "Rolling pre-release build of main, replaced on each snapshot run — not a numbered version.

Commit: ${SHA_SHORT}
Built: ${BUILT_AT}"

# ─── 5. Open the draft for review ─────────────────────────────────────────────

echo "==> Opening draft release"
gh release view snapshot --web

echo
echo "Done. Review the draft on GitHub and click Publish when ready."
