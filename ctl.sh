#!/bin/bash
# Toggle the NoSleepAgent master switch. Usage: ctl.sh [on|off|status]
FLAG="$HOME/.nosleepagent/enabled"
case "${1:-status}" in
  on)  echo 1 > "$FLAG"; echo "NoSleepAgent: ON" ;;
  off) echo 0 > "$FLAG"; echo "NoSleepAgent: OFF (the Mac will sleep normally)" ;;
  status|"")
    if [ "$(cat "$FLAG" 2>/dev/null)" = 0 ]; then echo "NoSleepAgent: OFF"; else echo "NoSleepAgent: ON"; fi ;;
  *) echo "usage: ctl.sh on|off|status"; exit 1 ;;
esac
