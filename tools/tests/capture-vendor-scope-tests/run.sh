#!/bin/sh
# Compile and run the capture vendor-scope checks.
# Self-contained: the rule under test is pure vendor-ID logic, while the real
# CaptureEngine.tabletOnly lives on a @MainActor type that pulls in IOKit and
# TabletKit. main.swift mirrors both it and TabletManager.knownVendorIDs —
# keep them in step if either changes.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"
BIN="$T/capture-vendor-scope-tests"

swiftc -O "$DIR/main.swift" -o "$BIN"
"$BIN"
