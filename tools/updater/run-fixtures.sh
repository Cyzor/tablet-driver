#!/bin/zsh
# MockTab — native macOS driver for supported drawing tablets
# SPDX-FileCopyrightText: 2026 MockTab contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Runs the helper's fixtures and prints pass or fail for each.
#
#   run-fixtures.sh [--live] [--signed <MockTab.app>] [--dmg <notarized dmg>] [--snapshot <notarized snapshot dmg>]
#
# Feed and redirect cases use a fresh ad-hoc build of main.swift and need
# nothing else. Staging cases need a notarized MockTab disk image; the ones
# past the signature step need a build with the signed helper inside.
# --live adds the cases that reach GitHub.
#
# The install case moves a stand-in app to the Trash.
set -u
setopt extended_glob
HERE=${0:A:h}
LIVE=0
SIGNED=${APP:-/tmp/updater-dd/Build/Products/Debug/MockTab.app}
DMG=${DIST:-$HERE/../../dist}/MockTab-0.6.1.dmg
SNAPSHOT=${DIST:-$HERE/../../dist}/MockTab-snapshot.dmg
while (( $# )); do
    case $1 in
    --live) LIVE=1 ;;
    --signed) SIGNED=$2; shift ;;
    --dmg) DMG=$2; shift ;;
    --snapshot) SNAPSHOT=$2; shift ;;
    *) echo "unknown option $1"; exit 2 ;;
    esac
    shift
done

T=$(mktemp -d /tmp/mocktab-fixtures.XXXXXX)
H=$T/updater
swiftc -O -o $H $HERE/../../MockTabUpdater/main.swift || exit 2
trap 'pkill -f $T/ 2>/dev/null; /bin/rm -rf $T' EXIT

PASS=0; FAIL=0
expect() { # name, expected, actual
    if [[ $3 == ${~2} ]]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); print -r -- "FAIL  $1"; print -r -- "      wanted: $2"; print -r -- "      got:    $3"; fi
}

# One line per result: the fields a case can turn on.
summary() {
    tail -1 | python3 -I -c '
import json, sys
try: r = json.loads(sys.stdin.read())
except Exception: print("no result"); sys.exit()
s = r.get("state", "?")
if s == "available":
    out = [s, r["channel"], r["version"], "installable" if r.get("installable") else "download-only"]
    if r.get("bridge"): out.append("bridge")
elif s == "upToDate": out = [s] + (["snapshot-waits"] if "snapshot" in r else [])
elif s == "unsupported": out = [s, r["minimumSystemVersion"]]
elif s == "failed": out = [s, r["kind"], r["reason"]]
else: out = [s]
print(" ".join(out))'
}

# MARK: - Feeds

python3 -I - $T <<'PY'
import json, sys
T = sys.argv[1]
P = "https://github.com/Cyzor/tablet-driver/releases/download/"
H = "a" * 64
def feed(name, omit=None, **over):
    f = {"schema": 1,
         "release": {"version": "0.6.1", "date": "2026-11-06T12:00Z", "url": P + "v0.6.1/MockTab-0.6.1.dmg", "sha256": H, "notes": ["r"]},
         "snapshot": {"date": "2026-11-11T10:00Z", "url": P + "snapshot/MockTab-snapshot.dmg", "sha256": H, "notes": ["s"]}}
    for k, v in over.items():
        if isinstance(v, dict) and k in f: f[k].update(v)
        else: f[k] = v
    if omit: del f[omit[0]][omit[1]]
    json.dump(f, open(f"{T}/{name}.json", "w"))
def bridge(v, d, **k):
    return dict({"version": v, "date": d, "url": P + f"v{v}/MockTab-{v}.dmg", "sha256": H, "notes": ["bridge " + v]}, **k)
feed("base")
feed("oldsnap", snapshot={"date": "2026-11-05T10:00Z"})
feed("schema2", schema=2)
feed("schema2nohash", schema=2, omit=("snapshot", "sha256"))
feed("sys99", release={"minimumSystemVersion": "99.0"})
feed("sys13", release={"minimumSystemVersion": "13.0"})
feed("sysbad", release={"minimumSystemVersion": "fourteen"})
feed("min2", minimumUpdater=2, release={"version": "0.8.0", "date": "2027-02-01T12:00Z"})
feed("bridges", minimumUpdater=3, release={"version": "0.8.0", "date": "2027-02-01T12:00Z"}, bridges=[
    bridge("0.6.5", "2026-12-01T12:00Z"),
    bridge("0.7.0", "2027-01-01T12:00Z", minimumUpdater=1),
    bridge("0.7.5", "2027-01-15T12:00Z", minimumUpdater=2),
    bridge("0.7.2", "2027-01-10T12:00Z", minimumSystemVersion="99.0"),
    {"version": "0.7.9", "shape": "future"},
    bridge("0.7.8", "2027-01-20T12:00Z", url="https://example.com/x.dmg"),
    {"version": "0.7.7", "date": "2027-01-19T12:00Z", "url": P + "v0.7.7/x.dmg"}])
for name, url in [("site", "https://mocktab.org/download/MockTab-0.6.1.dmg"),
                  ("site-near", "https://mocktab.org/downloads/MockTab-0.6.1.dmg"),
                  ("site-climb", "https://mocktab.org/download/../latest.json"),
                  ("site-http", "http://mocktab.org/download/MockTab-0.6.1.dmg"),
                  ("site-lookalike", "https://mocktab.org.example.com/download/MockTab-0.6.1.dmg")]:
    feed(name, release={"url": url})
open(f"{T}/malformed.json", "w").write('{ "release": ')
PY

check() { # feed, running label, expected, [--snapshot]
    expect "check $1, running $2 ${4:-}" "$3" "$($H check --running $2 --feed file://$T/$1.json ${4:-} | summary)"
}

# Channels: a release build sees a snapshot only when asked, and only one
# ahead of the latest release.
check base 0.6.1 "upToDate snapshot-waits"
check base 0.6.1 "available snapshot 0.6.1 installable" --snapshot
check base 0.6.0 "available release 0.6.1 installable"
check base 0.6.0 "available snapshot 0.6.1 installable" --snapshot
check oldsnap 0.6.1 "upToDate" --snapshot
check oldsnap 0.6.1 "upToDate"
check oldsnap 0.6.0 "available release 0.6.1 installable" --snapshot
check base 0.6.0-snapshot-20261105T1000Z "available release 0.6.1 installable"
check base 0.6.0-snapshot-20261105T1000Z "available snapshot 0.6.1 installable" --snapshot
check base 0.6.1-snapshot-20261108T1000Z "available snapshot 0.6.1 installable"
check base 0.6.1-snapshot-20261111T1000Z "upToDate" --snapshot
check base 0.6.2 "upToDate" --snapshot
check base garbage "failed usage *"

# Schema, system version, retired helper, bridges.
check schema2 0.6.0 "available release 0.6.1 installable"
check schema2nohash 0.6.0 "failed feed feed lacks a checksum"
check sys99 0.6.0 "unsupported 99.0"
check sys13 0.6.0 "available release 0.6.1 installable"
check sysbad 0.6.0 "failed feed feed malformed"
check min2 0.6.1 "available release 0.8.0 download-only"
check bridges 0.6.1 "available release 0.7.0 installable bridge"
check bridges 0.7.0 "available release 0.8.0 download-only"
check bridges 0.6.1-snapshot-20261220T1000Z "available release 0.7.0 installable bridge"

# Sources.
check site 0.6.0 "available release 0.6.1 installable"
for near in site-near site-climb site-http site-lookalike; do
    check $near 0.6.0 "failed feed feed points outside the project's releases"
done
check malformed 0.6.0 "failed feed feed malformed"
check missing 0.6.0 "failed network feed unavailable"
expect "feed from another host" "failed usage feed not allowed" \
    "$($H check --running 0.6.0 --feed https://example.com/latest.json | summary)"

# MARK: - Redirects

cat >$T/redirect.py <<'EOF'
import http.server, sys, urllib.parse
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        to = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)["to"][0]
        self.send_response(302); self.send_header("Location", to); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 8767), H).serve_forever()
EOF
(python3 -I $T/redirect.py >/dev/null 2>&1 &)
sleep 1
redirect() { # target, expected
    expect "redirect to $1" "$2" \
        "$($H stage --running 0.6.0 --local-ok --dest $T/stage --url "http://127.0.0.1:8767/x.dmg?to=$1" | summary)"
}
# A refused redirect leaves the 302 itself as the answer.
redirect https://example.com/x.dmg "failed network *302*"
redirect https://evilgithubusercontent.com/x.dmg "failed network *302*"
redirect http://objects.githubusercontent.com/x.dmg "failed network *302*"
redirect https://githubusercontent.com.example.com/x.dmg "failed network *302*"
if (( LIVE )); then
    # Followed: whatever comes back, it isn't the 302.
    redirect https://new-asset-host.githubusercontent.com/x.dmg "failed network ^*302*"
    expect "live download through GitHub's redirect" "failed rejected the updater itself isn't signed" \
        "$($H stage --running 0.6.0 --dest $T/stage --url https://github.com/Cyzor/tablet-driver/releases/download/v0.6.1/MockTab-0.6.1.dmg | summary)"
    expect "mocktab.org/download, nothing hosted yet" "failed network *404*" \
        "$($H stage --running 0.6.0 --dest $T/stage --url https://mocktab.org/download/none.dmg | summary)"
fi
pkill -f $T/redirect.py

# MARK: - Staging

if [[ ! -f $DMG ]]; then
    echo "skipped staging cases: no disk image at $DMG"
else
    mnt=$T/mnt; mkdir -p $mnt $T/sys99 $T/intel $T/standin
    hdiutil attach -quiet -nobrowse -readonly -mountpoint $mnt $DMG 2>/dev/null
    for d in sys99 intel standin; do ditto $mnt/MockTab.app $T/$d/MockTab.app; done
    hdiutil detach -quiet $mnt
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $T/standin/MockTab.app/Contents/Info.plist)
    /usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 99.0" $T/sys99/MockTab.app/Contents/Info.plist
    exe=$T/intel/MockTab.app/Contents/MacOS/MockTab
    other=x86_64; [[ $(uname -m) == x86_64 ]] && other=arm64
    lipo -thin $other $exe -output $exe
    hdiutil create -quiet -srcfolder $T/sys99 -volname MockTab -format UDZO $T/sys99.dmg
    hdiutil create -quiet -srcfolder $T/intel -volname MockTab -format UDZO $T/intel.dmg

    stage() { # helper, dmg, running, expected, name
        expect "$5" "$4" "$($1 stage --running $3 --local-ok --dest $T/stage --url file://$2 | summary)"
    }
    # The system check comes before the signature checks, so the ad-hoc build shows it.
    stage $H $T/sys99.dmg 0.0.1 "failed rejected it needs macOS 99.0 or later" "app that needs macOS 99.0"
    stage $H $T/intel.dmg 0.0.1 "failed rejected it isn't built for this Mac's processor" "app without this Mac's architecture"
    expect "nothing left in staging after a rejection" "gone" "$([[ -e $T/stage ]] && echo there || echo gone)"

    S=$SIGNED/Contents/Helpers/MockTabUpdater
    if [[ ! -x $S ]]; then
        echo "skipped signed-helper cases: no helper in $SIGNED"
    else
        stage $S $DMG $VERSION "failed rejected the download isn't newer than the running MockTab" "same version refused"
        stage $S $T/sys99.dmg 0.0.1 "failed rejected it needs macOS 99.0 or later" "signed helper: app that needs macOS 99.0"
        stage $S $DMG 0.0.1 "staged" "good image staged"
        expect "staged copy verifies" "verified" "$($S verify $T/stage/MockTab.app | summary)"

        # Install over a stand-in once a stand-in parent exits.
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0.0.1" $T/standin/MockTab.app/Contents/Info.plist
        sleep 1 &
        expect "install over a stand-in" "installed" \
            "$($S install --pid $! --running 0.0.1 --staged $T/stage/MockTab.app --target $T/standin/MockTab.app | summary)"
        expect "stand-in replaced" "$VERSION" \
            "$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $T/standin/MockTab.app/Contents/Info.plist)"
        expect "staging folder removed after install" "gone" "$([[ -e $T/stage ]] && echo there || echo gone)"

        # A staged copy edited before the install is refused.
        stage $S $DMG 0.0.1 "staged" "good image staged again"
        echo x >>"$(find $T/stage/MockTab.app/Contents/Resources -name '*.strings' | head -1)"
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0.0.1" $T/standin/MockTab.app/Contents/Info.plist 2>/dev/null
        sleep 1 &
        expect "edited staged copy refused at install" "failed rejected signature check failed*" \
            "$($S install --pid $! --running 0.0.1 --staged $T/stage/MockTab.app --target $T/standin/MockTab.app | summary)"
        defaults delete com.cyzor.mocktab _updateInstallFailed 2>/dev/null

        # The parent dies mid-download: the helper goes too, and cleans up.
        cat >$T/slow.py <<'EOF'
import http.server, os, sys, time
path = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Length", str(os.path.getsize(path))); self.end_headers()
        with open(path, "rb") as f:
            while chunk := f.read(30000):
                self.wfile.write(chunk); time.sleep(0.1)
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", 8768), H).serve_forever()
EOF
        (python3 -I $T/slow.py $DMG >/dev/null 2>&1 &)
        sleep 1
        (zsh -c "$S stage --running 0.0.1 --local-ok --dest $T/orphan --url http://127.0.0.1:8768/update.dmg >$T/orphan.out; sleep 30" &)
        sleep 4
        expect "download under way before the parent dies" "*progress*" "$(tail -1 $T/orphan.out)"
        kill -9 $(pgrep -f "zsh -c $S stage") 2>/dev/null
        sleep 1
        expect "helper gone within a second of its parent" "gone" "$(pgrep -f "$S stage" >/dev/null && echo there || echo gone)"
        expect "partial download removed" "gone" "$([[ -e $T/orphan ]] && echo there || echo gone)"
        pkill -f $T/slow.py

        # A real snapshot over a release of the same version.
        # The helper reads the release's build stamp from the app around it,
        # so each case re-signs a copy of the signed build with other keys.
        if [[ ! -f $SNAPSHOT ]]; then
            echo "skipped snapshot-over-release cases: no disk image at $SNAPSHOT"
        else
            hdiutil attach -quiet -nobrowse -readonly -mountpoint $mnt $SNAPSHOT 2>/dev/null
            SV=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $mnt/MockTab.app/Contents/Info.plist)
            hdiutil detach -quiet $mnt
            around() { # name, release?, version, stamp
                mkdir -p $T/$1; ditto $SIGNED $T/$1/MockTab.app
                local plist=$T/$1/MockTab.app/Contents/Info.plist
                [[ $2 == yes ]] && /usr/libexec/PlistBuddy -c "Add :MockTabRelease bool true" $plist
                /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $3" -c "Set :MockTabBuildStamp $4" $plist
                codesign --force --sign "Developer ID Application" --timestamp=none \
                    --preserve-metadata=identifier,entitlements,requirements,flags,runtime $T/$1/MockTab.app 2>/dev/null
            }
            over() { # name, expected, description
                expect "$3" "$2" "$($T/$1/MockTab.app/Contents/Helpers/MockTabUpdater stage --running $SV --local-ok --dest $T/stage-$1 --url file://$SNAPSHOT | summary)"
            }
            NOT_NEWER="failed rejected the download isn't newer than the running MockTab"
            around earlier yes $SV 20200101T0000Z
            around later yes $SV 20990101T0000Z
            around other yes 99.0.0 20200101T0000Z
            around plain no $SV 20200101T0000Z
            over earlier "staged" "snapshot over an earlier release of its version"
            over later "$NOT_NEWER" "snapshot over a release stamped later"
            over other "$NOT_NEWER" "label names a release the enclosing app isn't"
            over plain "$NOT_NEWER" "enclosing app isn't a release"
            sleep 1 &
            expect "install recheck applies the same stamp rule" "failed rejected the staged copy isn't newer than the running MockTab" \
                "$($T/later/MockTab.app/Contents/Helpers/MockTabUpdater install --pid $! --running $SV --staged $T/stage-earlier/MockTab.app --target $T/standin/MockTab.app | summary)"
            defaults delete com.cyzor.mocktab _updateInstallFailed 2>/dev/null
        fi
    fi
fi

echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
