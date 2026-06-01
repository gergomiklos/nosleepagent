#!/bin/bash
set -euo pipefail
LABEL="com.openlid.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
rm -f "$HOME/.claude/commands/openlid.md"

echo "Uninstalled ($LABEL) and removed the /openlid command."
echo "The four hooks in ~/.claude/settings.json are left in place;"
echo "remove them manually if you no longer want the state file updated."
