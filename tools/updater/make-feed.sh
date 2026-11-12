#!/bin/zsh
# Writes a simulated update feed and points MockTab at it.
#
#   make-feed.sh good       <dmg> [version]   real DMG, correct hash
#   make-feed.sh badhash    <dmg> [version]   real DMG, wrong hash
#   make-feed.sh tampered   <dmg> [version]   DMG whose app has an edited file
#   make-feed.sh missing    <dmg> [version]   URL to a file that isn't there
#   make-feed.sh malformed                    feed that isn't valid JSON
#   make-feed.sh unreachable                  feed URL on a closed port
#   make-feed.sh slow       <dmg> [version]   served at ~300 KB/s from 127.0.0.1:8766
#   make-feed.sh off                          remove both hidden keys
#   make-feed.sh pretend <label>              set UpdateSimulateRunningVersion
#
# version is what the feed claims (default 0.6.2). The helper still checks
# the DMG's real version against the running one.
set -eu
HERE=${0:A:h}
DIR=$HERE/out/feed
mkdir -p $DIR
MODE=${1:?mode}
DMG=${2:-}
VERSION=${3:-0.6.2}
DOMAIN=com.cyzor.mocktab

write_feed() { # url sha
    local sha_line=""
    [[ -n "$2" ]] && sha_line="\"sha256\": \"$2\","
    cat >$DIR/latest.json <<EOF
{
  "release": { "version": "$VERSION", "date": "$(date -u +%Y-%m-%dT%H:%MZ)", $sha_line
    "url": "$1",
    "notes": ["Simulated update ($MODE)", "A second note line to show wrapping in the Info pane"] },
  "snapshot": { "date": "2020-01-01T00:00Z", "url": "$1" }
}
EOF
    defaults write $DOMAIN UpdateFeedOverride "file://$DIR/latest.json"
}

case $MODE in
good|badhash|missing|slow)
    [[ -f $DMG ]] || { echo "no DMG: $DMG"; exit 1; }
    cp $DMG $DIR/update.dmg
    sha=$(shasum -a 256 $DIR/update.dmg | cut -d' ' -f1)
    url="file://$DIR/update.dmg"
    [[ $MODE == badhash ]] && sha=0000000000000000000000000000000000000000000000000000000000000000
    [[ $MODE == missing ]] && url="file://$DIR/not-there.dmg"
    if [[ $MODE == slow ]]; then
        url="http://127.0.0.1:8766/update.dmg"
        pkill -f "slow-server.py" 2>/dev/null || true
        cat >$DIR/slow-server.py <<'EOF'
import http.server, os, sys, time
root = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = os.path.join(root, "update.dmg")
        size = os.path.getsize(path)
        self.send_response(200)
        self.send_header("Content-Length", str(size))
        self.end_headers()
        with open(path, "rb") as f:
            while chunk := f.read(30000):
                self.wfile.write(chunk); time.sleep(0.1)
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", 8766), H).serve_forever()
EOF
        (python3 -I $DIR/slow-server.py $DIR >/dev/null 2>&1 &)
    fi
    write_feed $url $sha ;;
tampered)
    [[ -f $DMG ]] || { echo "no DMG: $DMG"; exit 1; }
    work=$(mktemp -d)
    mnt=$(hdiutil attach -nobrowse -readonly -mountrandom /tmp $DMG | awk -F'\t' '/\/tmp/{print $NF}')
    ditto "$mnt/MockTab.app" $work/MockTab.app
    hdiutil detach -quiet "$mnt"
    echo x >> "$(find $work/MockTab.app/Contents/Resources -name '*.strings' | head -1)"
    rm -f $DIR/update.dmg
    hdiutil create -quiet -srcfolder $work -volname MockTab -format UDZO $DIR/update.dmg
    rm -rf $work
    write_feed "file://$DIR/update.dmg" "$(shasum -a 256 $DIR/update.dmg | cut -d' ' -f1)" ;;
malformed)
    echo '{ "release": ' >$DIR/latest.json
    defaults write $DOMAIN UpdateFeedOverride "file://$DIR/latest.json" ;;
unreachable)
    defaults write $DOMAIN UpdateFeedOverride "http://127.0.0.1:9/latest.json" ;;
pretend)
    defaults write $DOMAIN UpdateSimulateRunningVersion "${2:?label}" ;;
off)
    pkill -f "slow-server.py" 2>/dev/null || true
    defaults delete $DOMAIN UpdateFeedOverride 2>/dev/null || true
    defaults delete $DOMAIN UpdateSimulateRunningVersion 2>/dev/null || true ;;
*) echo "unknown mode $MODE"; exit 1 ;;
esac
echo "feed: $(defaults read $DOMAIN UpdateFeedOverride 2>/dev/null || echo none)  pretend: $(defaults read $DOMAIN UpdateSimulateRunningVersion 2>/dev/null || echo none)"
