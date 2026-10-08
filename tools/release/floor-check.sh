#!/bin/bash
# Open a build of MockTab in a macOS 13 or 14 virtual machine, so it can be
# checked on the oldest systems it supports. GitHub no longer offers runners
# that old, so this is the only place those systems get exercised.
#
# Uses Tart (https://tart.run), which runs macOS VMs on Apple silicon. A VM
# can't pass a tablet through, so this checks everything except tablet input.
# Follow tools/release/floor-check.md once the VM is up.
#
# Usage:
#   tools/release/floor-check.sh --setup [13|14]       # one-time: download the VM (about 25 GB)
#   tools/release/floor-check.sh [13|14] [MockTab.app]  # open a build in the VM
#
# The app defaults to the last exported snapshot. It must be signed, because
# Apple silicon won't launch an unsigned app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

setup=false
if [[ "${1:-}" == "--setup" ]]; then
    setup=true
    shift
fi

version="${1:-13}"
case "$version" in
    13) image="ghcr.io/cirruslabs/macos-ventura-base:latest" ;;
    14) image="ghcr.io/cirruslabs/macos-sonoma-base:latest" ;;
    *) echo "floor-check: version must be 13 or 14" >&2; exit 2 ;;
esac
vm="mocktab-floor-$version"

if ! command -v tart >/dev/null; then
    echo "floor-check: Tart isn't installed. Install it with:" >&2
    echo "    brew install openai/tools/tart" >&2
    exit 1
fi

if $setup; then
    tart clone "$image" "$vm"
    echo "floor-check: $vm is ready. Run again without --setup to open a build."
    exit 0
fi

if ! tart list --quiet | grep -qx "$vm"; then
    echo "floor-check: no $vm VM yet. Run: tools/release/floor-check.sh --setup $version" >&2
    exit 1
fi

app="${2:-$ROOT/dist/build/export-snapshot/MockTab.app}"
if [[ ! -d "$app" ]]; then
    echo "floor-check: no app at $app. Pass the path to an exported MockTab.app." >&2
    exit 1
fi
codesign --verify "$app" 2>/dev/null || {
    echo "floor-check: $app isn't signed, and Apple silicon won't launch it." >&2
    exit 1
}

# Share a copy, not the original, so nothing in the VM can touch it.
staging="$(mktemp -d)"
ditto "$app" "$staging/MockTab.app"
echo "floor-check: opening $vm with $(defaults read "$app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "this build") shared."
echo "floor-check: in the VM, the app is in /Volumes/My Shared Files/mocktab. Log in as admin, password admin."
echo "floor-check: checklist: tools/release/floor-check.md"
tart run --dir="mocktab:$staging:ro" "$vm"
rm -rf "$staging"
