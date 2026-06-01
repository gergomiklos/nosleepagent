#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.openlid.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CMD_DIR="$HOME/.claude/commands"

"$DIR/build.sh"

# Seed the state file if missing.
mkdir -p "$HOME/.claude"
[ -f "$HOME/.claude/openlid.state" ] || echo idle > "$HOME/.claude/openlid.state"

# Merge the four hooks into settings.json (JSON-aware + idempotent; backs up
# the file before changing it). Leaves any existing hooks untouched.
python3 - "$HOME/.claude/settings.json" '~/.claude/openlid.state' <<'PY'
import json, os, shutil, sys
path, state = sys.argv[1], sys.argv[2]
busy, idle = f"echo busy > {state}", f"echo idle > {state}"
events = {"UserPromptSubmit": busy, "PreToolUse": busy, "PostToolUse": busy, "Stop": idle}
try:
    with open(path) as f: cfg = json.load(f)
except FileNotFoundError:
    cfg = {}
hooks = cfg.setdefault("hooks", {})
changed = False
for ev, cmd in events.items():
    arr = hooks.setdefault(ev, [])
    present = any(h.get("command") == cmd
                 for grp in arr if isinstance(grp, dict)
                 for h in grp.get("hooks", []))
    if not present:
        arr.append({"hooks": [{"type": "command", "command": cmd}]})
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

# Generate the LaunchAgent plist for *this* checkout (no hardcoded paths).
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DIR/bin/openlid</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$DIR/openlid.log</string>
    <key>StandardErrorPath</key>
    <string>$DIR/openlid.log</string>
</dict>
</plist>
PLIST_EOF

# Install the /openlid Claude Code command, pointed at this checkout's ctl.sh.
mkdir -p "$CMD_DIR"
cat > "$CMD_DIR/openlid.md" <<CMD_EOF
---
description: Toggle the OpenLid lid-close alarm (on/off/status)
allowed-tools: Bash($DIR/ctl.sh:*)
---
!\`$DIR/ctl.sh \$ARGUMENTS\`

The OpenLid switch has been updated (see output above). Confirm the new state in one short line; no other action needed.
CMD_EOF

# (Re)load the agent. Use the modern bootstrap/bootout API (macOS 11+).
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "Installed and loaded ($LABEL)."
echo "Status: launchctl print gui/$(id -u)/$LABEL | grep state"
echo "Logs:   $DIR/openlid.log"
echo "Restart any open Claude Code sessions so the new hooks take effect."
