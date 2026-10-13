#!/bin/bash
# Short hardware checks for the build under test. Works out which checks fit
# the hardware that's connected and still lack a result, builds what's
# missing, and prompts for each step. Run it as often as you like, in any
# order; results last until the next restart.
#
#   switch     Bluetooth-to-USB switch of a Wacom tablet, on A and on B, then
#              compares them. Needs a Wacom tablet on Bluetooth.
#   wacom      Every key, bezel button, ring, strip, pen, and touch surface on
#              each Wacom tablet you use, on B. Also checks that nothing but
#              MockTab moves the cursor meanwhile, and collects MockTab's errors.
#   xencelabs  Every Quick Keys control and Pen Display bezel button, on B.
#   strain     Pen latency at idle and while the Quick Keys pushes labels, on
#              Release builds of A and B. Needs a wired Wacom tablet and a
#              Quick Keys. Runs only when asked for with --only strain, since
#              you draw for it.
#
# A is origin/main (what's pushed) and B is HEAD, unless given. With
# --working, B is the working tree, uncommitted changes included.
#
# Usage:
#   tools/hardware-check/hardware-check.sh [--again] [--working] [--only wacom|switch|xencelabs|strain] [A] [B]
#
# --again discards earlier results of the checks chosen. The terminal needs
# Accessibility and Input Monitoring. Quits and relaunches MockTab as needed,
# then puts back the build that was running when it started.
set -euo pipefail

ROOT="$(git -C "$(dirname "$0")/../.." rev-parse --show-toplevel)"
HERE="$ROOT/tools/hardware-check"
WORK=/tmp/mocktab-hwcheck
RESULTS="$WORK/results"

again="" only="" working=""
while [[ "${1:-}" == --* ]]; do
    case $1 in
        --again) again=1 ;;
        --working) working=1 ;;
        --only) only=$2; shift ;;
        *) echo "hardware-check: unknown option $1"; exit 64 ;;
    esac
    shift
done
A=$(git -C "$ROOT" rev-parse --short "${1:-origin/main}")
if [[ -n "$working" ]]; then
    B=working
else
    B=$(git -C "$ROOT" rev-parse --short "${2:-HEAD}")
    [[ "$A" == "$B" ]] && { echo "hardware-check: A and B are the same commit ($A); use --working for uncommitted changes"; exit 1; }
    if [[ -n $(git -C "$ROOT" status --porcelain --untracked-files=no) ]]; then
        echo "hardware-check: note: uncommitted changes aren't in either build; --working includes them"
    fi
fi

mkdir -p "$WORK/bin" "$RESULTS" "$WORK/tabletkit"
# The Wacom check decodes with TabletKit, built here as a plain library.
KIT="$WORK/tabletkit"
if [[ ! -f "$KIT/libTabletKit.a" || -n $(find "$ROOT/TabletKit/Sources/TabletKit" -name '*.swift' -newer "$KIT/libTabletKit.a") ]]; then
    echo "hardware-check: building TabletKit for the checker"
    swiftc -O -parse-as-library -module-name TabletKit -package-name TabletKit -emit-module \
        -emit-module-path "$KIT/TabletKit.swiftmodule" -emit-library -static -o "$KIT/libTabletKit.a" \
        $(find "$ROOT/TabletKit/Sources/TabletKit" -name '*.swift')
    rm -f "$WORK/bin/wacom_pad_check"
fi
if [[ ! -x "$WORK/bin/wacom_pad_check" || "$HERE/wacom_pad_check.swift" -nt "$WORK/bin/wacom_pad_check" ]]; then
    swiftc -O -I "$KIT" -L "$KIT" -lTabletKit "$HERE/wacom_pad_check.swift" -o "$WORK/bin/wacom_pad_check"
fi
for tool in transport_switch_check xencelabs_check; do
    if [[ ! -x "$WORK/bin/$tool" || "$HERE/$tool.swift" -nt "$WORK/bin/$tool" ]]; then
        swiftc -O "$HERE/$tool.swift" -o "$WORK/bin/$tool"
    fi
done

# MARK: Builds

app_for() {
    if [[ "${2:-}" == Release ]]; then
        echo "$WORK/ddr-$1/Build/Products/Release/MockTab.app"
    else
        echo "$WORK/dd-$1/Build/Products/Debug/MockTab.app"
    fi
}

build() {
    local c=$1 config=${2:-Debug} src="$WORK/src-$1"
    local dd="$WORK/dd-$c"
    [[ "$config" == Release ]] && dd="$WORK/ddr-$c"
    if [[ "$c" == working ]]; then
        # Rebuilt every run; xcodebuild only redoes what changed.
        echo "hardware-check: building the working tree ($config)"
        xcodebuild -project "$ROOT/MockTab.xcodeproj" -scheme MockTab -configuration "$config" \
            -derivedDataPath "$dd" build >"$WORK/build-$c-$config.log" 2>&1 \
            || { echo "hardware-check: build of the working tree failed, see $WORK/build-$c-$config.log"; exit 1; }
        return
    fi
    [[ -d "$(app_for "$c" "$config")" ]] && return
    echo "hardware-check: building $c ($config), which takes a few minutes"
    if [[ ! -d "$src" ]]; then
        git -C "$ROOT" worktree add --detach "$src" "$c" >/dev/null
    fi
    # Unpushed TabletKit commits exist only in the local repo. Pass its path
    # for this one command: `git config` in a worktree would change the main
    # checkout's shared config.
    git -C "$src" -c protocol.file.allow=always -c submodule.TabletKit.url="$ROOT/TabletKit" \
        submodule update --init TabletKit >/dev/null
    xcodebuild -project "$src/MockTab.xcodeproj" -scheme MockTab -configuration "$config" \
        -derivedDataPath "$dd" build >"$WORK/build-$c-$config.log" 2>&1 \
        || { echo "hardware-check: build of $c failed, see $WORK/build-$c-$config.log"; exit 1; }
}

running_pid() { pgrep -x MockTab | head -1 || true; }
running_path() {
    local p
    p=$(running_pid)
    if [[ -n "$p" ]]; then ps -o comm= -p "$p" | sed 's#/Contents/MacOS/MockTab$##'; fi
}

quit_mocktab() {
    local path
    path=$(running_path)
    [[ -z "$path" ]] && return
    osascript -e "tell application \"$path\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 50); do [[ -z $(running_pid) ]] && return; sleep 0.2; done
    kill "$(running_pid)" 2>/dev/null || true
    sleep 1
}

launch() {
    quit_mocktab
    open -n "$1"
    for _ in $(seq 50); do [[ -n $(running_pid) ]] && break; sleep 0.2; done
    # Give the tablet's interfaces time to attach.
    sleep 3
}

use_build() {
    build "$1" "${2:-Debug}"
    [[ "$(running_path)" == "$(app_for "$1" "${2:-Debug}")" ]] || launch "$(app_for "$1" "${2:-Debug}")"
}

original=$(running_path)
restore() {
    if [[ -n "$original" && "$(running_path)" != "$original" ]]; then
        echo "hardware-check: relaunching $original"
        launch "$original"
    fi
}
trap restore EXIT

# MARK: Hardware

hid=$(ioreg -r -c IOHIDDevice -l 2>/dev/null)
has_wacom() { grep -q '"VendorID" = 1386$' <<<"$hid"; }
# Product ID of a Wacom tablet on USB, for the latency probe.
wired_wacom_pid() {
    awk '/\+-o /{t=""; v=""; p=""} /"Transport" = "USB"/{t=1} /"VendorID" = 1386$/{v=1}
         /"ProductID" = [1-9]/{p=$NF} t && v && p {printf "%x\n", p; exit}' <<<"$hid"
}
# A Wacom interface on Bluetooth, which the switch check starts from.
has_wacom_bluetooth() {
    awk '/\+-o /{t=""; v=""} /"Transport" = "Bluetooth/{t=1} /"VendorID" = 1386$/{v=1} t && v {f=1} END{exit !f}' <<<"$hid"
}
# Quick Keys wired and wireless, Pen Display 24 and 16.
has_xencelabs() { grep -qE '"ProductID" = (20994|20995|21005|21003)$' <<<"$hid"; }

wants() { [[ -z "$only" || "$only" == "$1" ]]; }
wants_explicitly() { [[ "$only" == "$1" ]]; }

# Runs a check. A switch run that doesn't count is offered again. The other
# checks save every run, and a device is done once a run used every control.
run() {
    local tool=$1 tag=$2 out=$3
    until "$WORK/bin/$tool" --pid "$(running_pid)" --label "$tag" --out "$out"; do
        [[ "$tool" != transport_switch_check ]] && return
        rm -f "$out"
        printf "Try again? [Y/n] "
        read -r answer
        [[ "$answer" == [nN]* ]] && return
    done
}

# --again discards only the results of the checks it's about to run.
[[ -n "$again" ]] && rm -f "$RESULTS/${only:-*}"-*.json "$RESULTS/${only:-*}"-*.txt
ran=""

if wants wacom; then
    # The checker skips tablets that already have a result.
    if has_wacom; then
        use_build "$B"
        run wacom_pad_check "B $B" "$RESULTS"
        ran=1
    else
        echo "wacom: no Wacom tablet connected, skipped"
    fi
fi

if wants xencelabs; then
    # The checker skips devices that already have a result.
    if has_xencelabs; then
        use_build "$B"
        run xencelabs_check "B $B" "$RESULTS"
        ran=1
    else
        echo "xencelabs: no Quick Keys or Pen Display connected, skipped"
    fi
fi

if wants switch; then
    if [[ -f "$RESULTS/switch-$A.json" && -f "$RESULTS/switch-$B.json" ]]; then
        echo "switch: already done on both builds"
    elif has_wacom_bluetooth; then
        # The build already running goes first, to save a relaunch.
        order="$B $A"
        [[ "$(running_path)" == "$(app_for "$A")" ]] && order="$A $B"
        for c in $order; do
            out="$RESULTS/switch-$c.json"
            [[ -f "$out" ]] && continue
            use_build "$c"
            tag=$([[ "$c" == "$A" ]] && echo "A $c" || echo "B $c")
            run transport_switch_check "$tag" "$out"
        done
        ran=1
    else
        echo "switch: no Wacom tablet on Bluetooth, skipped"
    fi
    if [[ -f "$RESULTS/switch-$A.json" && -f "$RESULTS/switch-$B.json" ]]; then
        echo
        "$WORK/bin/transport_switch_check" --compare "$RESULTS/switch-$A.json" "$RESULTS/switch-$B.json" || true
    fi
fi

if wants_explicitly strain; then
    pid=${STRAIN_PID:-$(wired_wacom_pid)}
    if [[ -z "$pid" ]]; then
        echo "strain: no Wacom tablet on USB, skipped"
    elif ! has_xencelabs; then
        echo "strain: no Quick Keys connected, skipped"
    else
        for c in $A $B; do
            out="$RESULTS/strain-$c.txt"
            [[ -f "$out" ]] && continue
            use_build "$c" Release
            echo
            echo "strain: $([[ "$c" == "$A" ]] && echo "A" || echo "B") $c"
            STRAIN_CONDITIONS="idle quickkeys" "$ROOT/tools/latency/strain-bench.sh" 056a "$pid" | tee "$out.part"
            mv "$out.part" "$out"
        done
        ran=1
        if [[ -f "$RESULTS/strain-$A.txt" && -f "$RESULTS/strain-$B.txt" ]]; then
            for c in $A $B; do
                echo
                echo "strain, $([[ "$c" == "$A" ]] && echo "A" || echo "B") $c:"
                grep -E '^(condition|idle|quickkeys) ' "$RESULTS/strain-$c.txt" || true
            done
        fi
    fi
fi

[[ -n "$ran" ]] || echo "hardware-check: nothing left to run for what's connected"
