#!/bin/sh
# MockTab — native macOS driver for supported drawing tablets
# SPDX-FileCopyrightText: 2026 MockTab contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Run tools/release/feed-check.sh on feeds made from one valid example, each
# changed in one way, and check which pass. Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../lib.sh"

CHECK="$ROOT/tools/release/feed-check.sh"
SHA=3a0a91db0c4882f99172e3838194c4a2c48900f88732a195cc6fef79ed86070c
cat >"$WORK/base.json" <<EOF
{
    "schema": 1,
    "release": {
        "version": "0.6.1",
        "date": "2026-11-06T23:01Z",
        "url": "https://github.com/Cyzor/tablet-driver/releases/download/v0.6.1/MockTab-0.6.1.dmg",
        "sha256": "$SHA",
        "minimumSystemVersion": "13.0",
        "notes": ["Wobbly taps stay clicks"]
    },
    "snapshot": {
        "date": "2026-11-18T00:12Z",
        "url": "https://mocktab.org/download/a6dda219cfe8fc65/MockTab-snapshot.dmg",
        "sha256": "$SHA",
        "notes": []
    }
}
EOF

passed=0
failed=0
# expect pass|fail NAME JQ_FILTER
expect() {
    jq "$3" "$WORK/base.json" >"$WORK/case.json"
    if sh -c '"$0" "$1" >/dev/null 2>&1' "$CHECK" "$WORK/case.json"; then got=pass; else got=fail; fi
    if [ "$got" = "$1" ]; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        echo "FAIL: $2: expected $1, got $got"
    fi
}

expect pass "valid feed" '.'
expect pass "no schema, no checksums" 'del(.schema, .release.sha256, .snapshot.sha256)'
expect pass "higher schema" '.schema = 2'
expect pass "unknown fields" '.extra = {"a": 1} | .release.extra = true'
expect pass "minimumUpdater and a bridge" '.minimumUpdater = 2 | .bridges = [.release + {minimumUpdater: 1}]'
expect pass "no bridges" 'del(.bridges)'

expect fail "not an object" '[.]'
expect fail "no release" 'del(.release)'
expect fail "no snapshot" 'del(.snapshot)'
expect fail "two-part version" '.release.version = "0.6"'
expect fail "prefixed version" '.release.version = "v0.6.1"'
expect fail "date with seconds" '.release.date = "2026-11-06T23:01:00Z"'
expect fail "date without zone" '.snapshot.date = "2026-11-18T00:12"'
expect fail "build stamp as date" '.snapshot.date = "20261118T0012Z"'
expect fail "plain HTTP" '.release.url |= sub("^https"; "http")'
expect fail "other host" '.release.url = "https://example.com/MockTab.dmg"'
expect fail "look-alike host" '.release.url = "https://mocktab.org.example.com/download/x.dmg"'
expect fail "downloads path" '.snapshot.url = "https://mocktab.org/downloads/x.dmg"'
expect fail "climbing path" '.snapshot.url = "https://mocktab.org/download/../latest.json"'
expect fail "encoded path" '.snapshot.url = "https://mocktab.org/download/%2e%2e/x.dmg"'
expect fail "query" '.snapshot.url = "https://mocktab.org/download/x.dmg?y"'
expect fail "notes as string" '.release.notes = "one"'
expect fail "notes with a number" '.release.notes = ["one", 2]'
expect fail "uppercase checksum" '.release.sha256 |= ascii_upcase'
expect fail "short checksum" '.release.sha256 = "abc"'
expect fail "schema 1 without a checksum" 'del(.snapshot.sha256)'
expect fail "schema 0" '.schema = 0'
expect fail "schema as string" '.schema = "1"'
expect fail "fractional minimumUpdater" '.minimumUpdater = 1.5'
expect fail "one-part system version" '.release.minimumSystemVersion = "13"'
expect fail "system version as number" '.release.minimumSystemVersion = 13.0'
expect fail "bridges as object" '.bridges = {}'
expect fail "bridge without checksum" '.bridges = [.release | del(.sha256)]'
expect fail "bridge outside prefixes" '.bridges = [.release | .url = "https://example.com/x.dmg"]'

printf '{' >"$WORK/broken.json"
if sh -c '"$0" "$1" >/dev/null 2>&1' "$CHECK" "$WORK/broken.json"; then
    failed=$((failed + 1)); echo "FAIL: unreadable JSON passed"
else
    passed=$((passed + 1))
fi

echo "feed-check: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
