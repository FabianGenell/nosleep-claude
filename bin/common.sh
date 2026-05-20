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

# Drop state files for any session whose caffeinate is no longer alive.
# Called at the top of every hook so refcounts stay accurate even if a prior
# session crashed without firing Stop / SessionEnd.
clean_stale_sessions() {
    local cf sid pid
    for cf in "$NOSLEEP_DIR"/*.cpid; do
        [ -e "$cf" ] || continue
        pid=$(cat "$cf" 2>/dev/null)
        if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
            sid=$(basename "$cf" .cpid)
            rm -f "$cf" "$NOSLEEP_DIR/$sid.lid"
        fi
    done
}

# How many sessions currently hold a "lid lock" (i.e. .lid marker).
# pmset disablesleep is a global setting, so we only flip it when this count
# transitions 0→1 (acquire) and 1→0 (release).
count_active_lids() {
    local n=0 lf
    for lf in "$NOSLEEP_DIR"/*.lid; do
        [ -e "$lf" ] && n=$((n+1))
    done
    printf '%s' "$n"
}

# Raw pmset toggles. Silently no-op if sudoers rule isn't installed.
_pmset_disable() { sudo -n /usr/bin/pmset -b disablesleep 1 >/dev/null 2>&1; }
_pmset_enable()  { sudo -n /usr/bin/pmset -b disablesleep 0 >/dev/null 2>&1; }

# Acquire the global lid lock on behalf of $SESSION_ID. If we're the first
# session needing it, flip pmset. Otherwise just record our hold.
# Sets LID_FILE iff the lock was successfully acquired (or joined).
lid_lock_acquire() {
    local lid_file="$NOSLEEP_DIR/$SESSION_ID.lid"
    if [ "$(count_active_lids)" = "0" ]; then
        # We'd be the first holder — only mark held if pmset actually flipped.
        if _pmset_disable; then
            touch "$lid_file"
            log "session=$SESSION_ID lid-close sleep DISABLED (first holder)"
        fi
    else
        # Already disabled by another session; just join the count.
        touch "$lid_file"
        log "session=$SESSION_ID lid lock joined (now $(( $(count_active_lids) + 0 )) holders)"
    fi
}

# Release our hold on the global lid lock. If we were the last holder, flip
# pmset back to its normal state.
lid_lock_release() {
    local lid_file="$NOSLEEP_DIR/$SESSION_ID.lid"
    [ -f "$lid_file" ] || return 0
    rm -f "$lid_file"
    clean_stale_sessions
    if [ "$(count_active_lids)" = "0" ]; then
        _pmset_enable
        log "session=$SESSION_ID lid-close sleep RE-ENABLED (last holder)"
    else
        log "session=$SESSION_ID lid lock released ($(count_active_lids) holders remain)"
    fi
}
