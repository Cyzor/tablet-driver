#!/usr/bin/env bash
# MockTab — record a published release or snapshot in mocktab-web/latest.json,
# which drives the website's Check for Updates page.
#
# Run after clicking Publish on GitHub. The publish-triggered workflow runs this
# same script; use it by hand as a fallback or to preview (--dry-run).
#
# Usage:
#   tools/release/update-latest.sh v0.4.3      # a numbered release
#   tools/release/update-latest.sh snapshot    # the rolling snapshot
#   tools/release/update-latest.sh --dry-run v0.4.3
#
# Reads everything from GitHub, so local git state doesn't matter:
#   release  — version from the tag, publish time, DMG link, notes from that
#              version's CHANGELOG.md line (split at semicolons).
#   snapshot — build stamp from the annotated snapshot tag's message (UTC,
#              e.g. 20260927T1432Z, copied from the built app), DMG link,
#              notes from CHANGELOG.md's Unreleased line.
# Refuses drafts: the page must never link to a download that isn't public.
#
# Writes $MOCKTAB_WEB/latest.json (default: ../mocktab-web beside this repo)
# and commits it there. Does not push.

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$(dirname "$0")/../.."

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then DRY_RUN=1; shift; fi
TAG="${1:?usage: update-latest.sh [--dry-run] <vX.Y.Z | snapshot>}"
REPO="Cyzor/tablet-driver"
WEB="${MOCKTAB_WEB:-../mocktab-web}"

# CHANGELOG line: "- [v0.4.2](…) — first item; second item; third item."
# Prints its items as a JSON array.
changelog_notes() {
    local line
    line=$(grep -m1 -F -- "$1" CHANGELOG.md || true)
    [[ -n "$line" ]] || { echo "error: no CHANGELOG.md line starting '$1'." >&2; exit 1; }
    sed -E 's/^[^—]*— //; s/\.$//' <<<"$line" \
        | jq -R 'split("; ") | map((.[:1] | ascii_upcase) + .[1:])'
}

INFO=$(gh release view "$TAG" --repo "$REPO" --json isDraft,publishedAt,assets)
if [[ $(jq -r .isDraft <<<"$INFO") == "true" ]]; then
    echo "error: $TAG is still a draft. Publish it on GitHub first." >&2
    exit 1
fi
URL=$(jq -r '[.assets[] | select(.name | endswith(".dmg"))][0].url // empty' <<<"$INFO")
[[ -n "$URL" ]] || { echo "error: $TAG has no DMG attached." >&2; exit 1; }

if [[ "$TAG" == "snapshot" ]]; then
    # Lightweight tags have no message; the object type tells them apart.
    REF=$(gh api "repos/$REPO/git/ref/tags/snapshot")
    if [[ $(jq -r .object.type <<<"$REF") != "tag" ]]; then
        echo "error: snapshot tag has no build stamp (made before stamping existed)." >&2
        exit 1
    fi
    STAMP=$(gh api "repos/$REPO/git/tags/$(jq -r .object.sha <<<"$REF")" --jq .message | head -1)
    if [[ ! "$STAMP" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})Z$ ]]; then
        echo "error: snapshot tag message '$STAMP' isn't a build stamp." >&2
        exit 1
    fi
    m=("${BASH_REMATCH[@]}")
    NOTES=$(changelog_notes "- Unreleased —")
    ENTRY=$(jq -n --arg d "${m[1]}-${m[2]}-${m[3]}T${m[4]}:${m[5]}Z" --arg u "$URL" \
        --argjson n "$NOTES" '{snapshot: {date: $d, url: $u, notes: $n}}')
else
    VERSION="${TAG#v}"
    PUBLISHED=$(jq -r .publishedAt <<<"$INFO")
    NOTES=$(changelog_notes "- [$TAG](")
    ENTRY=$(jq -n --arg v "$VERSION" --arg d "${PUBLISHED:0:16}Z" --arg u "$URL" \
        --argjson n "$NOTES" '{release: {version: $v, date: $d, url: $u, notes: $n}}')
fi

if (( DRY_RUN )); then
    echo "$ENTRY"
    exit 0
fi

[[ -f "$WEB/latest.json" ]] || { echo "error: $WEB/latest.json not found (set MOCKTAB_WEB)." >&2; exit 1; }
jq --indent 4 --argjson e "$ENTRY" '. * $e' "$WEB/latest.json" >"$WEB/latest.json.tmp"
mv "$WEB/latest.json.tmp" "$WEB/latest.json"

if git -C "$WEB" diff --quiet -- latest.json; then
    echo "latest.json already records $TAG. Nothing to do."
    exit 0
fi
git -C "$WEB" commit -q -m "Record $TAG as latest" -- latest.json
echo "Committed latest.json in $WEB. Push mocktab-web to put it live."
