#!/bin/bash
# Toggle the OpenLid master switch. Usage: ctl.sh [on|off|status]
FLAG="$HOME/.claude/openlid.enabled"
case "${1:-status}" in
  on)  echo 1 > "$FLAG"; echo "OpenLid: ON" ;;
  off) echo 0 > "$FLAG"; echo "OpenLid: OFF (lid close will be silent)" ;;
  status|"")
    if [ "$(cat "$FLAG" 2>/dev/null)" = 0 ]; then echo "OpenLid: OFF"; else echo "OpenLid: ON"; fi ;;
  *) echo "usage: ctl.sh on|off|status"; exit 1 ;;
esac
