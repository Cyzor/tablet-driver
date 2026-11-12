#!/bin/zsh
# Edge cases for the helper's install command, run without the UI.
# Everything happens on scratch disk images under $W; nothing touches
# /Applications or the user's Trash.
#
#   edge-tests.sh setup | volume | readonly | kill [step-ms] | intel | teardown
set -u
HERE=${0:A:h}
H=${APP:-/tmp/updater-dd/Build/Products/Debug/MockTab.app}/Contents/Helpers/MockTabUpdater
DIST=${DIST:-$HERE/../../dist}
W=$HOME/Applications/MockTab-Update-Test/edge
DOMAIN=com.cyzor.mocktab
OLD=$W/master/old/MockTab.app       # genuine 0.6.0
NEW=$W/master/new/MockTab.app       # genuine 0.6.1, staged by the helper
A=$W/mnt/A                          # volume holding the "installed" app
B=$W/mnt/B                          # second volume, for the cross-volume case

ver() { /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null || echo none; }
ok()  { $H verify "$1" >/dev/null 2>&1 && echo verified || echo NOT-VERIFIED; }
gone_pid() { /usr/bin/true & local p=$!; wait $p; echo $p; }
clear_fail_key() { defaults delete $DOMAIN _updateInstallFailed 2>/dev/null; }
fresh() { # dir-for-target dir-for-staged
    /bin/rm -rf "$1" "$2"; mkdir -p "$1" "$2"
    ditto $OLD "$1/MockTab.app"; ditto $NEW "$2/MockTab.app"
}
mkvol() { # name mountpoint
    local img=$W/$1.asif
    [[ -d $2 ]] && mount | grep -q " on $2 " && return
    [[ -f $img ]] || diskutil image create blank --fs APFS --size 2g --volumeName Edge$1 $img >/dev/null
    mkdir -p $2
    diskutil image attach --nobrowse --mountPoint $2 $img >/dev/null
}

case ${1:?mode} in
setup)
    mkdir -p $W/master/old $W/master/new
    if [[ ! -d $OLD ]]; then
        m=$W/mnt/old; mkdir -p $m
        diskutil image attach --readOnly --nobrowse --mountPoint $m $DIST/MockTab-0.6.0.dmg >/dev/null
        ditto $m/MockTab.app $OLD; diskutil eject $m >/dev/null
    fi
    if [[ ! -d $NEW ]]; then
        $H stage --running 0.6.0 --url "file://$DIST/MockTab-0.6.1.dmg" --dest $W/master/new-stage --local-ok \
            --sha256 $(shasum -a 256 $DIST/MockTab-0.6.1.dmg | cut -d' ' -f1)
        mv $W/master/new-stage/MockTab.app $NEW && rmdir $W/master/new-stage
    fi
    mkvol A $A; mkvol B $B
    echo "old $(ver $OLD) $(ok $OLD)   new $(ver $NEW) $(ok $NEW)" ;;

volume)
    clear_fail_key
    fresh $A/Apps $B/Stage
    out=$($H install --pid $(gone_pid) --running 0.6.0 --staged $B/Stage/MockTab.app --target $A/Apps/MockTab.app 2>&1); st=$?
    echo "exit $st: $out"
    echo "target: $(ver $A/Apps/MockTab.app) $(ok $A/Apps/MockTab.app)"
    echo "staged left: $(ls $B/Stage 2>/dev/null | tr '\n' ' ')"
    echo "failure note: $(defaults read $DOMAIN _updateInstallFailed 2>&1)"
    clear_fail_key ;;

readonly)
    for variant in folder app; do
        clear_fail_key
        fresh $A/Apps $A/Stage
        [[ $variant == folder ]] && chmod a-w $A/Apps || chmod a-w $A/Apps/MockTab.app
        printf 'writable? folder %s app %s\n' "$([[ -w $A/Apps ]] && echo yes || echo no)" "$([[ -w $A/Apps/MockTab.app ]] && echo yes || echo no)"
        out=$($H install --pid $(gone_pid) --running 0.6.0 --staged $A/Stage/MockTab.app --target $A/Apps/MockTab.app 2>&1); st=$?
        chmod u+w $A/Apps $A/Apps/MockTab.app 2>/dev/null
        echo "[$variant read-only] exit $st: $out"
        echo "  target: $(ver $A/Apps/MockTab.app) $(ok $A/Apps/MockTab.app)   staged left: $(ls $A/Stage | tr '\n' ' ')"
        echo "  failure note: $(defaults read $DOMAIN _updateInstallFailed 2>&1)"
    done
    clear_fail_key ;;

kill)
    step=${2:-25}
    : > $W/kill-results.txt
    for (( d = 0; d <= ${3:-1500}; d += step )); do
        for sig in TERM KILL; do
            fresh $A/Apps $A/Stage
            $H install --pid $(gone_pid) --running 0.6.0 --staged $A/Stage/MockTab.app --target $A/Apps/MockTab.app >/dev/null 2>&1 &
            hp=$!
            sleep $(( d / 1000.0 ))
            kill -$sig $hp 2>/dev/null && how=killed || how=finished
            wait $hp 2>/dev/null
            t=$A/Apps/MockTab.app
            line="$d $sig $how target=$(ver $t) $(ok $t) apps=$(ls $A/Apps | wc -l | tr -d ' ') stage=[$(ls $A/Stage | tr '\n' ' ')]"
            [[ -d $A/Stage/MockTab.app ]] && line+=" stagedver=$(ver $A/Stage/MockTab.app)"
            echo $line >> $W/kill-results.txt
        done
    done
    clear_fail_key
    echo "runs: $(wc -l < $W/kill-results.txt)"
    awk '{print $3, $4, $5, $6, $7}' $W/kill-results.txt | sort | uniq -c ;;

intel)
    clear_fail_key
    echo "slice: $(lipo -archs $H)"
    echo "check: $(arch -x86_64 $H check --running 0.6.0 --feed https://mocktab.org/latest.json 2>&1 | cut -c1-120)"
    echo "verify: $(arch -x86_64 $H verify $NEW 2>&1)"
    /bin/rm -rf $A/Stage-x86
    echo "stage: $(arch -x86_64 $H stage --running 0.6.0 --url "file://$DIST/MockTab-0.6.1.dmg" --dest $A/Stage-x86 --local-ok \
        --sha256 $(shasum -a 256 $DIST/MockTab-0.6.1.dmg | cut -d' ' -f1) 2>&1 | tail -1)"
    /bin/rm -rf $A/Apps; mkdir -p $A/Apps; ditto $OLD $A/Apps/MockTab.app
    echo "install: $(arch -x86_64 $H install --pid $(gone_pid) --running 0.6.0 --staged $A/Stage-x86/MockTab.app --target $A/Apps/MockTab.app 2>&1)"
    echo "target: $(ver $A/Apps/MockTab.app) $(ok $A/Apps/MockTab.app)"
    clear_fail_key ;;

teardown)
    for m in $A $B; do mount | grep -q " on $m " && diskutil eject $m >/dev/null; done
    /bin/rm -rf $W
    clear_fail_key
    echo "removed $W" ;;
esac
