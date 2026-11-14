#!/bin/zsh
# MockTab — native macOS driver for supported drawing tablets
# SPDX-FileCopyrightText: 2026 MockTab contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Ends the UI walkthrough and puts everything back.
set -u
HERE=${0:A:h}
# Without a backup from ui-session.sh there is nothing to put back.
[[ -s $HERE/out/.last-ui-backup && -d $(cat $HERE/out/.last-ui-backup)/ApplicationSupport ]] \
    || { echo "No backup from ui-session.sh; nothing changed."; exit 1; }
TEST=$HOME/Applications/MockTab-Update-Test
for app in $(pgrep -lf "MockTab-Update-Test/MockTab.app/Contents/MacOS/MockTab" | awk '{print $1}'); do kill -TERM $app; done
osascript -e "tell application \"$TEST/MockTab.app\" to quit" 2>/dev/null
while pgrep -f "MockTab-Update-Test/MockTab.app/Contents/MacOS" >/dev/null; do sleep 0.2; done
$HERE/make-feed.sh off
BACKUP=$(cat $HERE/out/.last-ui-backup)
# import merges, so clear what the test may have added first; the backup
# puts back any it had.
for k in _updateInstallPending _updateInstallFailed updateLastChecked checkForUpdatesAutomatically; do
    defaults delete com.cyzor.mocktab $k 2>/dev/null
done
defaults import com.cyzor.mocktab $BACKUP/com.cyzor.mocktab.plist
AS="$HOME/Library/Application Support/com.cyzor.mocktab"
mv "$AS" "$HOME/.Trash/com.cyzor.mocktab-AppSupport-after-ui-$(date +%H%M%S)"
ditto $BACKUP/ApplicationSupport "$AS"
[[ -d $TEST ]] && mv $TEST "$HOME/.Trash/MockTab-Update-Test-$(date +%H%M%S)"
rm -rf "$HOME/Library/Caches/com.cyzor.mocktab/Update"
echo "Restored settings from $BACKUP; test copy in the Trash."
