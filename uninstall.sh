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
echo "The activity hooks are left in place in:"
echo "  ~/.claude/settings.json   (Claude Code)"
echo "  ~/.codex/hooks.json       (Codex)"
echo "Remove the 'touch …/.nosleepagent/activity' entries manually if you no"
echo "longer want them. State dir ~/.nosleepagent can be deleted too."
