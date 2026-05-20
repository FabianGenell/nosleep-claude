---
description: Show nosleep-claude status and recent activity
---

!"${CLAUDE_PLUGIN_ROOT}/bin/nosleep-claude" status

!echo "" && echo "--- recent log ---" && "${CLAUDE_PLUGIN_ROOT}/bin/nosleep-claude" logs

Show the user the status and log output above verbatim. Do not add commentary. If the sudoers rule shows as DISABLED and they want lid-closed support on battery, tell them to run the following in their terminal:

  sudo "${CLAUDE_PLUGIN_ROOT}/bin/nosleep-claude" enable-lid-closed

Substitute the actual plugin path when telling them.
