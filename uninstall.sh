#!/bin/bash
# Removes nosleep-claude (LaunchAgent + script + sudoers rule) for the current user.
set -u

LABEL="com.genell.nosleep-claude"
BIN_DIR="$HOME/.local/bin"
SCRIPT_PATH="$BIN_DIR/nosleep-claude"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
SUDOERS_FILE="/etc/sudoers.d/nosleep-claude"
UID_NUM="$(id -u)"

echo "Uninstalling nosleep-claude..."

launchctl bootout "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 || true
echo "  unloaded LaunchAgent"

rm -f "$PLIST_PATH"; echo "  removed $PLIST_PATH"

# Re-enable lid-close sleep before we lose the rule
if [ -f "$SUDOERS_FILE" ] && [ -x "$SCRIPT_PATH" ]; then
    "$SCRIPT_PATH" uninstall-sudoers || true
elif [ -f "$SUDOERS_FILE" ]; then
    sudo rm -f "$SUDOERS_FILE"
    echo "  removed $SUDOERS_FILE"
fi

rm -f "$SCRIPT_PATH"; echo "  removed $SCRIPT_PATH"

echo "Done."
