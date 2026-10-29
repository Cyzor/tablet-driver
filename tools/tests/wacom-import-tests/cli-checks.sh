#!/bin/sh
# Runs the Wacom import command end to end against a scratch settings domain
# and a temporary folder: choosing a tablet, refusing without confirmation, a
# dry run, a write, and undoing it with the saved copy. Exits non-zero on
# failure. Never touches com.cyzor.mocktab.
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
DOMAIN="com.cyzor.mocktab.wacom-import-cli-tests"
BACKUP="$DIR/fixtures/sample.wacomprefs"
T="$(mktemp -d)"
FAILED=0

cleanup() {
    defaults delete "$DOMAIN" >/dev/null 2>&1
    rm -rf "$T"
}
trap cleanup EXIT

fail() { echo "FAIL: $1"; FAILED=1; }

# Two tablets MockTab knows, so the command has to be told which.
/usr/bin/python3 -I - "$T/seed.plist" <<'EOF'
import json, plistlib, sys
tablets = [{"id": 0x357, "nickname": "PTH-660", "modelName": "PTH-660"},
           {"id": 0x3F9, "nickname": "PTK-870", "modelName": "PTK-870"}]
plistlib.dump({"_knownTablets": json.dumps(tablets).encode(), "device-0x357.calibrationJSON": "keep"},
              open(sys.argv[1], "wb"), fmt=plistlib.FMT_BINARY)
EOF
defaults delete "$DOMAIN" >/dev/null 2>&1
defaults import "$DOMAIN" "$T/seed.plist"

run() { sh "$ROOT/tools/wacom-import/run.sh" --domain "$DOMAIN" --save-to "$T/saved" "$@" "$BACKUP" >"$T/out" 2>&1; }
has() { defaults read "$DOMAIN" "$1" >/dev/null 2>&1; }

run --apply --dry-run
[ $? -ne 0 ] && grep -q -- "--tablet 1: Intuos Pro M" "$T/out" && grep -q -- "--tablet 2: Intuos Pro L" "$T/out" \
    || fail "two known tablets: asks for --tablet"

run --apply --tablet 9 --dry-run
[ $? -ne 0 ] && grep -q "no tablet 9" "$T/out" || fail "a tablet number out of range is refused"

run --apply --tablet 3 --dry-run
[ $? -ne 0 ] && grep -q "no tablet 3 with a product ID" "$T/out" || fail "a tablet without a product ID is refused"

run --apply --tablet 1 --dry-run
[ $? -eq 0 ] && grep -q "Dry run" "$T/out" && grep -q "device-0x357.expressKeyBindings" "$T/out" \
    || fail "dry run lists the change"
has device-0x357.expressKeyBindings && fail "dry run writes nothing"
[ -e "$T/saved" ] && fail "dry run saves nothing"

run --apply --tablet 1 </dev/null
[ $? -ne 0 ] && grep -q "add --yes" "$T/out" || fail "without a terminal, --yes is required"
has device-0x357.expressKeyBindings && fail "an unconfirmed run writes nothing"

run --apply --tablet 1 --yes
[ $? -eq 0 ] && grep -q "Written" "$T/out" || fail "write: $(tail -3 "$T/out")"
has device-0x357.expressKeyBindings || fail "write sets ExpressKeys"
[ "$(defaults read "$DOMAIN" device-0x357.calibrationJSON 2>/dev/null)" = "keep" ] || fail "write keeps unrelated settings"
SAVED="$(ls "$T/saved"/mocktab-before-wacom-import-*.plist 2>/dev/null | head -1)"
[ -n "$SAVED" ] || fail "write saves a copy first"
grep -q "defaults delete $DOMAIN" "$T/out" && grep -q "defaults import $DOMAIN '$SAVED'" "$T/out" \
    || fail "write prints the undo commands"

if [ -n "$SAVED" ]; then
    defaults delete "$DOMAIN"
    defaults import "$DOMAIN" "$SAVED"
    has device-0x357.expressKeyBindings && fail "undo restores the earlier settings"
    [ "$(defaults read "$DOMAIN" device-0x357.calibrationJSON 2>/dev/null)" = "keep" ] || fail "undo keeps the rest"
fi

[ $FAILED -eq 0 ] && echo "Command checks passed."
exit $FAILED
