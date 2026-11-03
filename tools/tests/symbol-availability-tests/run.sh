#!/bin/sh
# MockTab — native macOS driver for supported drawing tablets
# SPDX-FileCopyrightText: 2026 MockTab contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Fail when the app names an SF Symbol newer than its deployment target
# without a fallback. A missing symbol draws nothing and raises no error.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
python3 -I "$DIR/check_symbols.py" "$ROOT"
