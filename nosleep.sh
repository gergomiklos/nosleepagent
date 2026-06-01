#!/bin/bash
# NoSleepAgent daemon — runs as root via a LaunchDaemon.
#
# Keeps the Mac awake (including with the lid closed) while a Claude Code
# session has been active recently, then restores normal sleep once it goes
# quiet. There is no state machine: the only thing stored is the time of the
# last activity (the mtime of $ACTIVITY, touched by the Claude Code hooks).
#
#   recent activity  -> pmset disablesleep 1  (stay awake, lid open or closed)
#   gone quiet        -> pmset disablesleep 0  (sleep normally)
#
# Usage: nosleep.sh <activity-file> <enabled-flag>
set -u

ACTIVITY="${1:?activity file path required}"
ENABLED="${2:?enabled flag path required}"

WINDOW=600     # consider the session active if touched within the last 10 min
INTERVAL=30    # how often to re-check

# Remember what we last told pmset so we only call it when it actually changes.
state=""

set_sleep() {   # $1: 1 = stay awake (disable sleep), 0 = allow normal sleep
    [ "$1" = "$state" ] && return
    pmset -a disablesleep "$1" >/dev/null 2>&1
    state="$1"
}

# Always leave the machine able to sleep again if we're told to stop or die.
cleanup() { set_sleep 0; exit 0; }
trap cleanup TERM INT

set_sleep 0   # start from a known-safe baseline

while true; do
    want=0
    # Off switch (`/nosleep off`) wins, and we only act on a real activity file.
    if [ "$(cat "$ENABLED" 2>/dev/null)" != "0" ] && [ -f "$ACTIVITY" ]; then
        now=$(date +%s)
        mtime=$(stat -f %m "$ACTIVITY" 2>/dev/null || echo 0)
        [ $((now - mtime)) -le "$WINDOW" ] && want=1
    fi
    set_sleep "$want"
    sleep "$INTERVAL"
done
