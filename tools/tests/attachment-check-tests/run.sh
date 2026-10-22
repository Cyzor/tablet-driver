#!/bin/sh
# Run the attachment-check decision tests against the real workflow script,
# .github/scripts/attachment_check.py. Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
python3 -I "$DIR/test_attachment_check.py" "$ROOT/.github/scripts"
