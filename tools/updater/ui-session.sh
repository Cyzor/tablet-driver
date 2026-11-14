#!/bin/zsh
# MockTab — native macOS driver for supported drawing tablets
# SPDX-FileCopyrightText: 2026 MockTab contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Starts a UI walkthrough of the update row. Quit the Xcode Debug build first.
set -eu
HERE=${0:A:h}
APP=${APP:-/tmp/updater-dd/Build/Products/Debug/MockTab.app}
TEST=$HOME/Applications/MockTab-Update-Test
DMG=${DIST:-$HERE/../../dist}/MockTab-0.6.1.dmg
if pgrep -x MockTab >/dev/null; then echo "A MockTab is still running; quit it first."; exit 1; fi

BACKUP=$HERE/out/settings-backup-ui-$(date -u +%Y%m%dT%H%MZ)
mkdir -p $BACKUP
defaults export com.cyzor.mocktab $BACKUP/com.cyzor.mocktab.plist
ditto "$HOME/Library/Application Support/com.cyzor.mocktab" $BACKUP/ApplicationSupport
echo $BACKUP > $HERE/out/.last-ui-backup

rm -rf $TEST && mkdir -p $TEST && ditto $APP $TEST/MockTab.app
$HERE/make-feed.sh slow $DMG
$HERE/make-feed.sh pretend 0.6.0
# Opens on the "Updated to" state, as after an install.
defaults write com.cyzor.mocktab _updateInstallPending \
    '{ from = "0.0.0"; display = "0.6.0"; notes = ("Note lines carried over from the install", "So the What'"'"'s New button has something to show"); }'
open $TEST/MockTab.app
echo "Running the test copy from $TEST. Restore with ui-restore.sh."
