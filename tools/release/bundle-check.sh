#!/usr/bin/env bash
# MockTab — native macOS driver for supported drawing tablets
# SPDX-FileCopyrightText: 2026 MockTab contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Fail unless an exported MockTab.app keeps the updater's promises:
#
#   - The driver never connects: MockTab's executable links no networking
#     framework and imports no networking API, and MockTab/ and TabletKit's
#     sources use none.
#   - The helper is MockTabUpdater alone in Contents/Helpers, signed with the
#     app's team and its own identifier under the hardened runtime, linking
#     only system libraries, naming only the feed and the two download
#     prefixes, and running only base-system tools.
#   - Nothing persists: no LaunchAgent, LaunchDaemon, login item, XPC
#     service, plug-in, or system extension in the bundle.
#   - LSMinimumSystemVersion is no lower than any executable's own minimum,
#     since the helper trusts it before installing.
#   - With --release, the app is marked as a release, so it ignores the
#     helper's simulation keys.
#
# Usage:
#   tools/release/bundle-check.sh [--release] <path/to/MockTab.app>
set -euo pipefail

RELEASE=0
if [[ "${1:-}" == "--release" ]]; then RELEASE=1; shift; fi
APP="${1:?usage: bundle-check.sh [--release] <MockTab.app>}"
APP=$(cd "$APP" && pwd)
cd "$(dirname "$0")/../.."

MAIN="$APP/Contents/MacOS/MockTab"
HELPER="$APP/Contents/Helpers/MockTabUpdater"
HELPER_SOURCE="MockTabUpdater/main.swift"
status=0
fail() { echo "bundle-check: $*" >&2; status=1; }

# Networking as it shows up in a Swift or Objective-C import table.
NETWORK_SYMBOLS='URLSession|NSURLConnection|NSURLDownload|NWConnection|NWListener|NWBrowser|_nw_|CFNetwork|CFHTTP|CFSocket|CFStreamCreatePairWithSocket|WKWebView|_getaddrinfo$|_connect$|_socket$'
NETWORK_LIBRARIES='Network\.framework|CFNetwork\.framework|WebKit\.framework'
NETWORK_SOURCE='URLSession|NSURLConnection|NWConnection|NWListener|import Network|CFNetwork|CFHTTP|CFSocket|WKWebView|getaddrinfo'

imports() { for arch in $(lipo -archs "$1"); do nm -u -arch "$arch" "$1"; done | sort -u; }
libraries() { otool -L "$1" | grep -v ':$' | awk '{print $1}' | sort -u; }

# The driver never connects.
[[ -f "$MAIN" ]] || { echo "bundle-check: no executable at $MAIN" >&2; exit 1; }
if found=$(imports "$MAIN" | grep -E "$NETWORK_SYMBOLS"); then
    fail "MockTab imports networking API: $(tr '\n' ' ' <<<"$found")"
fi
if found=$(libraries "$MAIN" | grep -E "$NETWORK_LIBRARIES"); then
    fail "MockTab links $(tr '\n' ' ' <<<"$found")"
fi
if found=$(grep -rlE "$NETWORK_SOURCE" MockTab TabletKit/Sources --include='*.swift'); then
    fail "networking API in sources: $(tr '\n' ' ' <<<"$found")"
fi

# The helper.
if [[ ! -f "$HELPER" ]]; then
    fail "no helper at Contents/Helpers/MockTabUpdater"
else
    extra=$(find "$APP/Contents/Helpers" -mindepth 1 ! -path "$HELPER")
    [[ -z "$extra" ]] || fail "Contents/Helpers holds more than MockTabUpdater: $(tr '\n' ' ' <<<"$extra")"

    # Proves the symbol pattern still matches how URLSession links; without
    # this, a rename would let MockTab's check above pass vacuously.
    imports "$HELPER" | grep -q 'NSURLSession' \
        || fail "the helper doesn't import NSURLSession, so the networking pattern needs a look"

    while IFS= read -r lib; do
        [[ "$lib" =~ ^/System/Library/Frameworks/(Foundation|CoreFoundation|Security|CryptoKit)\.framework/ \
           || "$lib" =~ ^/usr/lib/(libSystem\.B|libobjc\.A)\.dylib$ \
           || "$lib" =~ ^/usr/lib/swift/libswift[A-Za-z_]*\.dylib$ ]] \
            || fail "the helper links $lib"
    done < <(libraries "$HELPER")

    app_team=$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
    helper_sign=$(codesign -dv "$HELPER" 2>&1)
    [[ "$(sed -n 's/^Identifier=//p' <<<"$helper_sign")" == "com.cyzor.mocktab.updater" ]] \
        || fail "the helper's identifier isn't com.cyzor.mocktab.updater"
    helper_team=$(sed -n 's/^TeamIdentifier=//p' <<<"$helper_sign")
    [[ -n "$app_team" && "$app_team" != "not set" && "$helper_team" == "$app_team" ]] \
        || fail "the helper's team ($helper_team) isn't the app's ($app_team)"
    grep -q 'flags=.*(runtime)' <<<"$helper_sign" || fail "the helper isn't under the hardened runtime"

    # Long literals sit in the binary as text; short ones may not, so the
    # source is checked too.
    expected=$'https://github.com/Cyzor/tablet-driver/releases/download/\nhttps://mocktab.org/download/\nhttps://mocktab.org/latest.json'
    in_binary=$(strings -a "$HELPER" | grep -oE '[a-z]+://[^[:space:]"]*' | sort -u)
    [[ "$in_binary" == "$expected" ]] || fail "the helper's addresses aren't exactly the feed and the two prefixes: $(tr '\n' ' ' <<<"$in_binary")"
    in_source=$(grep -ohE '"[a-z]+://[^"]*"' "$HELPER_SOURCE" | tr -d '"' | sort -u)
    [[ "$in_source" == "$expected" ]] || fail "$HELPER_SOURCE names other addresses: $(tr '\n' ' ' <<<"$in_source")"

    while IFS= read -r tool; do
        [[ "$tool" =~ ^/(usr/bin|usr/sbin|bin|sbin)/[a-z]+$ ]] || fail "the helper runs $tool, outside the base system"
    done < <(grep -ohE 'run\("[^"]+"' "$HELPER_SOURCE" | sed 's/^run("//; s/"$//' | sort -u)
    [[ $(grep -c 'executableURL' "$HELPER_SOURCE") -eq 1 ]] \
        || fail "$HELPER_SOURCE starts processes outside run()"
    ! grep -vE '^[[:space:]]*//' "$HELPER_SOURCE" | grep -qE 'xcrun|/Applications/Xcode|/Library/Developer' \
        || fail "$HELPER_SOURCE calls developer tools"
fi

# Nothing persists.
for dir in Library/LaunchAgents Library/LaunchDaemons Library/LoginItems Library/SystemExtensions XPCServices PlugIns; do
    [[ ! -e "$APP/Contents/$dir" ]] || fail "the bundle contains Contents/$dir"
done
while IFS= read -r -d '' plist; do
    if plutil -convert xml1 -o - "$plist" 2>/dev/null | grep -qE '<key>(ProgramArguments|MachServices|RunAtLoad)</key>'; then
        fail "${plist#"$APP"/} looks like a launchd job"
    fi
done < <(find "$APP" -name '*.plist' -print0)

# The helper refuses an update that claims a newer macOS than this Mac runs,
# and trusts the claim otherwise.
INFO="$APP/Contents/Info.plist"
claimed=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO" 2>/dev/null || true)
if [[ ! "$claimed" =~ ^[0-9]+\.[0-9]+$ ]]; then
    fail "LSMinimumSystemVersion '$claimed' isn't MAJOR.MINOR"
else
    while IFS= read -r -d '' file; do
        lipo -archs "$file" >/dev/null 2>&1 || continue
        for arch in $(lipo -archs "$file"); do
            minos=$(vtool -arch "$arch" -show-build "$file" 2>/dev/null | awk '/minos/{print $2; exit}')
            [[ -n "$minos" ]] || continue
            lowest=$(printf '%s\n%s\n' "$minos" "$claimed" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)
            [[ "$lowest" == "$minos" ]] \
                || fail "${file#"$APP"/} ($arch) needs macOS $minos, above LSMinimumSystemVersion $claimed"
        done
    done < <(find "$APP/Contents" -type f -perm -u+x -print0)
fi

if (( RELEASE )); then
    [[ $(/usr/libexec/PlistBuddy -c 'Print :MockTabRelease' "$INFO" 2>/dev/null) == "true" ]] \
        || fail "a release build lacks MockTabRelease, so it would honor the simulation keys"
fi

[[ $status -eq 0 ]] && echo "bundle-check: driver makes no connections; helper, bundle, and macOS floor check out"
exit $status
