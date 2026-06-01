#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.nosleepagent.daemon"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
CMD_DIR="$HOME/.claude/commands"
ACTIVITY="$HOME/.claude/nosleep.activity"
ENABLED="$HOME/.claude/nosleep.enabled"

chmod +x "$DIR/nosleep.sh" "$DIR/ctl.sh"

# Seed the master switch ON. Don't seed the activity file: with no activity yet,
# the daemon correctly starts in the "let it sleep" state.
mkdir -p "$HOME/.claude"
[ -f "$ENABLED" ] || echo 1 > "$ENABLED"

# Merge the activity hooks into settings.json (JSON-aware + idempotent; backs up
# the file before changing it). Every prompt and tool call refreshes the
# last-activity timestamp; there is deliberately no Stop hook, so a finished
# turn simply ages out of the 10-minute window.
python3 - "$HOME/.claude/settings.json" "$ACTIVITY" <<'PY'
import json, os, shutil, sys
path, activity = sys.argv[1], sys.argv[2]
touch = f"touch {activity}"
events = ["UserPromptSubmit", "PreToolUse", "PostToolUse"]
try:
    with open(path) as f: cfg = json.load(f)
except FileNotFoundError:
    cfg = {}
hooks = cfg.setdefault("hooks", {})
changed = False
for ev in events:
    arr = hooks.setdefault(ev, [])
    present = any(h.get("command") == touch
                 for grp in arr if isinstance(grp, dict)
                 for h in grp.get("hooks", []))
    if not present:
        arr.append({"hooks": [{"type": "command", "command": touch}]})
        changed = True
if changed:
    if os.path.exists(path): shutil.copy(path, path + ".bak")
    d = os.path.dirname(path)
    if d: os.makedirs(d, exist_ok=True)
    with open(path, "w") as f: json.dump(cfg, f, indent=2); f.write("\n")
    print("hooks: added to settings.json (backup at settings.json.bak)")
else:
    print("hooks: already present")
PY

# Install the /nosleep Claude Code command, pointed at this checkout's ctl.sh.
mkdir -p "$CMD_DIR"
cat > "$CMD_DIR/nosleep.md" <<CMD_EOF
---
description: Toggle NoSleepAgent keep-awake (on/off/status)
allowed-tools: Bash($DIR/ctl.sh:*)
---
!\`$DIR/ctl.sh \$ARGUMENTS\`

The NoSleepAgent switch has been updated (see output above). Confirm the new state in one short line; no other action needed.
CMD_EOF

# The daemon flips a root-only power setting (pmset disablesleep), so it must run
# as root via a LaunchDaemon. Everything below this point needs sudo.
echo "Installing the system daemon (requires sudo)…"
TMP_PLIST="$(mktemp)"
cat > "$TMP_PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DIR/nosleep.sh</string>
        <string>$ACTIVITY</string>
        <string>$ENABLED</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$DIR/nosleep.log</string>
    <key>StandardErrorPath</key>
    <string>$DIR/nosleep.log</string>
</dict>
</plist>
PLIST_EOF

sudo install -m 644 -o root -g wheel "$TMP_PLIST" "$PLIST"
rm -f "$TMP_PLIST"

# (Re)load the daemon in the system domain.
sudo launchctl bootout system "$PLIST" 2>/dev/null || true
sudo launchctl bootstrap system "$PLIST"

echo "Installed and loaded ($LABEL)."
echo "Status: sudo launchctl print system/$LABEL | grep state"
echo "Logs:   $DIR/nosleep.log"
echo "Restart any open Claude Code sessions so the new hooks take effect."
