#!/bin/bash
# Shared helpers for nosleep-claude hooks. Sourced, not executed.
set -u

NOSLEEP_DIR="/tmp/nosleep-claude"
SUDOERS_FILE="/etc/sudoers.d/nosleep-claude"
LOG_FILE="$NOSLEEP_DIR/nosleep-claude.log"

# Runtime state lives in /tmp and dies with the boot; the event history has to
# outlive it, so it goes under the user's state dir.
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/nosleep-claude"
EVENTS_FILE="$STATE_DIR/events.tsv"

# How long the Mac stays awake after Claude's last activity. Every prompt,
# tool call, and stop restarts a caffeinate with this timeout, so sleep
# prevention always self-expires. A missed Stop hook can't pin the machine
# awake indefinitely.
GRACE_SECS="${NOSLEEP_GRACE_SECS:-900}"

# Skip the restart if the current timer was refreshed less than this many
# seconds ago, so per-tool-call hooks don't churn processes.
REFRESH_THROTTLE_SECS=60

mkdir -p "$NOSLEEP_DIR" 2>/dev/null || true
mkdir -p "$STATE_DIR" 2>/dev/null || true

log() {
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${HOOK:-?}" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

# Hook JSON arrives once on stdin, so read it whole and pick fields out of it.
read_hook_input() { HOOK_INPUT=$(cat); }

hook_field() {
    local field="$1"
    [ -n "${HOOK_INPUT:-}" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$HOOK_INPUT" | jq -r --arg f "$field" '.[$f] // empty' 2>/dev/null
    elif command -v python3 >/dev/null 2>&1; then
        printf '%s' "$HOOK_INPUT" | python3 -c '
import json, sys
try:
    value = json.load(sys.stdin).get(sys.argv[1])
except Exception:
    value = None
if isinstance(value, str):
    print(value)
' "$field" 2>/dev/null
    else
        printf '%s' "$HOOK_INPUT" \
            | grep -o "\"$field\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
            | head -1 \
            | sed 's/.*"\([^"]*\)"$/\1/'
    fi
}

# Tabs and newlines would break the event file, and a whole prompt is more
# than any readout needs.
one_line() {
    tr '\t\n\r' '   ' \
        | sed -e 's/<pasted_content[^>]*>//g' -e 's#</pasted_content[^>]*>##g' \
              -e 's/  */ /g' -e 's/^ //' -e 's/ $//' \
        | cut -c1-90
}

# Append one row to the history the stats command reads back.
record_event() {
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$(date +%s)" "$1" "$SESSION_ID" "${PROJECT:-}" "${LABEL:-}" \
        >> "$EVENTS_FILE" 2>/dev/null || true
}

# What this session is: the directory it runs in, and the last thing it was
# asked to do. Kept beside the timer so the menu bar can name live sessions.
write_session_meta() {
    printf '%s\t%s\t%s\n' "${PROJECT:-}" "${LABEL:-}" "$(date +%s)" \
        > "$NOSLEEP_DIR/$SESSION_ID.meta" 2>/dev/null || true
}

kill_pid_silent() {
    local pid="$1"
    [ -n "$pid" ] || return 0
    kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null
    return 0
}

# (Re)start this session's self-expiring caffeinate timer. Pass "force" to
# always restart (used on prompt/stop so the grace window starts exactly at
# that moment); without it, a recent-enough timer is left alone.
refresh_caffeinate() {
    local force="${1:-}"
    local cpid_file="$NOSLEEP_DIR/$SESSION_ID.cpid"
    local pid
    if [ -f "$cpid_file" ]; then
        pid=$(cat "$cpid_file" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            if [ "$force" != "force" ]; then
                local age
                age=$(( $(date +%s) - $(stat -f %m "$cpid_file" 2>/dev/null || echo 0) ))
                [ "$age" -lt "$REFRESH_THROTTLE_SECS" ] && return 0
            fi
            kill "$pid" 2>/dev/null
        fi
    fi
    caffeinate -imsu -t "$GRACE_SECS" </dev/null >/dev/null 2>&1 &
    echo $! > "$cpid_file"
    log "session=$SESSION_ID caffeinate=$! (refreshed, expires in ${GRACE_SECS}s)"
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
            rm -f "$cf" "$NOSLEEP_DIR/$sid.lid" "$NOSLEEP_DIR/$sid.meta"
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
        # We'd be the first holder, so only mark held if pmset actually flipped.
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
