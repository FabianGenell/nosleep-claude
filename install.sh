#!/bin/bash
# Installs nosleep-claude as a LaunchAgent under the current user.
# Use this if you're installing from a git clone. For Homebrew, see the README.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.genell.nosleep-claude"
BIN_DIR="$HOME/.local/bin"
SCRIPT_PATH="$BIN_DIR/nosleep-claude"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUM="$(id -u)"

echo "Installing nosleep-claude..."

mkdir -p "$BIN_DIR"
install -m 0755 "$REPO_DIR/bin/nosleep-claude" "$SCRIPT_PATH"
echo "  daemon  -> $SCRIPT_PATH"

mkdir -p "$HOME/Library/LaunchAgents"
sed "s|__SCRIPT_PATH__|$SCRIPT_PATH|g" \
    "$REPO_DIR/LaunchAgents/$LABEL.plist" > "$PLIST_PATH"
echo "  plist   -> $PLIST_PATH"

launchctl bootout "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST_PATH"
launchctl enable "gui/$UID_NUM/$LABEL"
echo "  loaded  -> launchctl gui/$UID_NUM/$LABEL"

echo
echo "Optional: enable lid-closed sleep prevention on battery."
echo "  Adds a passwordless-sudo rule scoped to: pmset -b disablesleep *"
echo "  Without it, closing the lid on battery will still sleep the machine."
read -r -p "Enable lid-closed support? [y/N] " RESP
if [[ "$RESP" =~ ^[Yy]$ ]]; then
    "$SCRIPT_PATH" install-sudoers
fi

echo
echo "Done. nosleep-claude is now active and will auto-start at login."
echo "  status:  nosleep-claude status"
echo "  logs:    tail -f /tmp/nosleep-claude.log"
echo "  remove:  $REPO_DIR/uninstall.sh"
