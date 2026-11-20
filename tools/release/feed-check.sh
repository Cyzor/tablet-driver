#!/usr/bin/env bash
# MockTab — native macOS driver for supported drawing tablets
# SPDX-FileCopyrightText: 2026 MockTab contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Fail unless a latest.json meets the feed contract that every shipped
# MockTabUpdater reads. update-latest.sh runs this before it commits a feed;
# run it by hand on mocktab-web/latest.json after editing the feed directly.
#
# Usage:
#   tools/release/feed-check.sh <latest.json>
#
# Needs only bash and jq, since the publish workflow runs it on Linux.
set -euo pipefail

FEED="${1:?usage: feed-check.sh <latest.json>}"
[[ -f "$FEED" ]] || { echo "feed-check: $FEED not found" >&2; exit 1; }

# Formats are fixed for good: every helper ever shipped parses them. Download
# addresses must sit under the helper's two prefixes, with nothing that could
# climb out of them once a URL is standardized.
PROGRAM='
def version: type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$");
def date: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}Z$");
def system: type == "string" and test("^[0-9]+\\.[0-9]+$");
def hash: type == "string" and test("^[0-9a-f]{64}$");
def count: type == "number" and . >= 0 and floor == .;
def download: type == "string"
    and (startswith("https://github.com/Cyzor/tablet-driver/releases/download/")
         or startswith("https://mocktab.org/download/"))
    and (test("/\\.\\.?(/|$)") | not)
    and (test("[\\s\\\\?#%]") | not);
def notes: type == "array" and all(.[]; type == "string");

def problems($name; $versioned; $hashed):
    if type != "object" then "\($name) is missing or not an object"
    else
        (if $versioned and (.version | version | not) then "\($name).version isn'"'"'t MAJOR.MINOR.PATCH" else empty end),
        (if .date | date | not then "\($name).date isn'"'"'t YYYY-MM-DDTHH:MMZ" else empty end),
        (if .url | download | not then "\($name).url is outside the download prefixes" else empty end),
        (if .notes | notes | not then "\($name).notes isn'"'"'t an array of strings" else empty end),
        (if has("sha256") then
            (if .sha256 | hash | not then "\($name).sha256 isn'"'"'t 64 lowercase hex digits" else empty end)
         elif $hashed then "\($name) lacks sha256, which schema 1 requires"
         else empty end),
        (if has("minimumSystemVersion") and (.minimumSystemVersion | system | not)
         then "\($name).minimumSystemVersion isn'"'"'t MAJOR.MINOR" else empty end),
        (if has("minimumUpdater") and (.minimumUpdater | count | not)
         then "\($name).minimumUpdater isn'"'"'t a whole number" else empty end)
    end;

if type != "object" then "the feed isn'"'"'t a JSON object"
else
    ((.schema // 0) | if type == "number" then . else 0 end) as $schema
    | (if has("schema") and ((.schema | count | not) or .schema < 1)
       then "schema isn'"'"'t a whole number of 1 or more" else empty end),
      (if has("minimumUpdater") and (.minimumUpdater | count | not)
       then "minimumUpdater isn'"'"'t a whole number" else empty end),
      (.release | problems("release"; true; $schema >= 1)),
      (.snapshot | problems("snapshot"; false; $schema >= 1)),
      (if has("bridges") then
          (if .bridges | type != "array" then "bridges isn'"'"'t an array"
           else .bridges | to_entries[] | .key as $i | .value | problems("bridges[\($i)]"; true; $schema >= 1)
           end)
       else empty end)
end
'

if ! PROBLEMS=$(jq -r "$PROGRAM" "$FEED" 2>&1); then
    echo "feed-check: $FEED isn't readable JSON: $PROBLEMS" >&2
    exit 1
fi
if [[ -n "$PROBLEMS" ]]; then
    while IFS= read -r line; do echo "feed-check: $FEED: $line" >&2; done <<<"$PROBLEMS"
    exit 1
fi
echo "feed-check: $FEED meets the feed contract"
