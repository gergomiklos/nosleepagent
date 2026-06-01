#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.nosleepagent.daemon"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
CMD_DIR="$HOME/.claude/commands"

# Tool-neutral state, shared by Claude Code and Codex hooks and read by the
# daemon. The only thing stored is the last-activity timestamp + an on/off flag.
STATE_DIR="$HOME/.nosleepagent"
ACTIVITY="$STATE_DIR/activity"
ENABLED="$STATE_DIR/enabled"

chmod +x "$DIR/nosleep.sh" "$DIR/ctl.sh"

# Seed the master switch ON. Don't seed the activity file: with no activity yet,
# the daemon correctly starts in the "let it sleep" state.
mkdir -p "$STATE_DIR"
[ -f "$ENABLED" ] || echo 1 > "$ENABLED"

# Merge the activity hooks into a tool's hook config. Claude Code (settings.json)
# and Codex (hooks.json) use the same nested shape under a top-level "hooks" key,
# so one routine handles both. JSON-aware + idempotent; backs up before changing.
# Every prompt and tool call refreshes the last-activity timestamp; there is
# deliberately no Stop hook, so a finished turn simply ages out of the window.
wire_hooks() {  # $1: hook-config json path, $2: activity file
  python3 - "$1" "$2" <<'PY'
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
    print(f"hooks: added to {path} (backup at {os.path.basename(path)}.bak)")
else:
    print(f"hooks: already present in {path}")
PY
}

wire_hooks "$HOME/.claude/settings.json" "$ACTIVITY"   # Claude Code
wire_hooks "$HOME/.codex/hooks.json"     "$ACTIVITY"   # Codex

# Install the /nosleep Claude Code command, pointed at this checkout's ctl.sh.
# (Codex has no equivalent; use ./ctl.sh there.)
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
echo "Codex: run /hooks in the Codex CLI and trust the new hooks."
