#!/bin/sh
# MockTab — native macOS driver for supported drawing tablets
# SPDX-FileCopyrightText: 2026 MockTab contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Compile and run the checks for mocktab: links against the real
# MockTabLink.swift and the Help section list. Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../lib.sh"

swift_test link-tests "$ROOT/MockTab/App/MockTabLink.swift" "$ROOT/MockTab/UI/Help/HelpSection.swift" "$ROOT/MockTab/UI/Help/HelpContent.swift" "$DIR/main.swift"
"$TEST_BIN"
