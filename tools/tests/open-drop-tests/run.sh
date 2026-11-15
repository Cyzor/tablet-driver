#!/bin/sh
# MockTab — native macOS driver for supported drawing tablets
# SPDX-FileCopyrightText: 2026 MockTab contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Compile and run the checks for items dragged onto button rows against the
# real ButtonOpenAction.swift. Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../lib.sh"

swift_test open-drop-tests "$ROOT/MockTab/App/ButtonOpenAction.swift" "$DIR/main.swift"
"$TEST_BIN"
