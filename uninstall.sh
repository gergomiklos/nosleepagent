#!/bin/bash
set -euo pipefail
LABEL="com.nosleepagent.daemon"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

echo "Removing the system daemon (requires sudo)…"
# Booting out triggers the daemon's cleanup, which restores normal sleep.
sudo launchctl bootout system "$PLIST" 2>/dev/null || true
sudo rm -f "$PLIST"
# Belt and suspenders: make sure sleep is re-enabled even if the daemon was gone.
sudo pmset -a disablesleep 0 >/dev/null 2>&1 || true

rm -f "$HOME/.claude/commands/nosleep.md"

echo "Uninstalled ($LABEL) and removed the /nosleep command."
echo "The activity hooks in ~/.claude/settings.json are left in place;"
echo "remove the 'touch …/nosleep.activity' entries manually if you no longer want them."
