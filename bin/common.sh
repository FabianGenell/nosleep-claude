#!/bin/bash
# Shared helpers for nosleep-claude hooks. Sourced, not executed.
set -u

NOSLEEP_DIR="/tmp/nosleep-claude"
SUDOERS_FILE="/etc/sudoers.d/nosleep-claude"
LOG_FILE="$NOSLEEP_DIR/nosleep-claude.log"

mkdir -p "$NOSLEEP_DIR" 2>/dev/null || true

log() {
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${HOOK:-?}" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

# Read session_id from hook JSON on stdin. Falls back to grep if jq missing.
read_session_id() {
    local input
    input=$(cat)
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null
    else
        printf '%s' "$input" \
            | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' \
            | head -1 \
            | sed 's/.*"\([^"]*\)"$/\1/'
    fi
}

# Walk up the process tree from this hook until we find the `claude` CLI.
# Hook is launched as a shell child of claude, so the chain is typically:
#   claude -> sh -> this script. We walk up at most 10 levels for safety.
find_claude_pid() {
    local pid="$PPID" i=0
    while [ -n "$pid" ] && [ "$pid" -gt 1 ] && [ "$i" -lt 10 ]; do
        local comm
        comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' \n' | sed 's|.*/||')
        if [ "$comm" = "claude" ]; then
            printf '%s' "$pid"
            return 0
        fi
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' \n')
        i=$((i+1))
    done
    return 1
}

kill_pid_silent() {
    local pid="$1"
    [ -n "$pid" ] || return 0
    kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null
    return 0
}

disable_lid_sleep() { sudo -n /usr/bin/pmset -b disablesleep 1 >/dev/null 2>&1; }
enable_lid_sleep()  { sudo -n /usr/bin/pmset -b disablesleep 0 >/dev/null 2>&1; }
