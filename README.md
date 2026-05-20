# nosleep-claude

A Claude Code plugin that keeps your Mac awake **only while Claude is actively working on a prompt**. The moment Claude finishes, sleep returns to normal.

No daemon, no LaunchAgent, no polling. Just two hooks: `UserPromptSubmit` starts a `caffeinate` tied to Claude's process; `Stop` kills it. If Claude crashes or the terminal is closed, `caffeinate -w` drops automatically.

## Install

In Claude Code:

```
/plugin marketplace add FabianGenell/nosleep-claude
/plugin install nosleep-claude@nosleep-claude
```

Then restart Claude Code so the hooks load. That's it — every prompt now blocks system sleep for the duration of Claude's response.

### Optional: lid-closed support on battery

By default, closing the lid on battery still puts the Mac to sleep (`caffeinate` doesn't override clamshell sleep). To prevent that too:

```sh
sudo ~/.claude/plugins/marketplaces/nosleep-claude/nosleep-claude/bin/nosleep-claude enable-lid-closed
```

(Run `/nosleep-claude` inside Claude to see the exact path on your machine.)

That installs a tightly-scoped passwordless-sudo rule for `pmset -b disablesleep`. After that, lid-closed sleep is suppressed during any active prompt — and re-enabled when Claude finishes.

## Behavior

While Claude is responding:

- ✅ No idle sleep, no disk sleep, no system sleep
- ✅ With lid-closed support: lid can close, Claude keeps running
- ✅ Display can still sleep (screen lock still works as expected)

While Claude is idle (CLI open, waiting for input):

- ✅ Mac sleeps normally per your Energy Saver settings
- ✅ Battery is not held hostage

When Claude crashes / terminal is killed / Ctrl+C interrupts:

- `caffeinate -w <claude_pid>` auto-exits when Claude dies, so nothing leaks
- Worst case (Ctrl+C without next prompt): caffeinate stays alive until session ends — handled by `SessionEnd` hook
- All edge cases tilt toward "stay awake too long" rather than "sleep mid-task" (the safe direction)

## Uninstall

```
/plugin uninstall nosleep-claude
```

To also remove the lid-closed sudoers rule:

```sh
sudo ~/.claude/plugins/.../bin/nosleep-claude disable-lid-closed
```

## How it works

Four hooks in `hooks/hooks.json`:

| Hook | What it does |
|------|--------------|
| `UserPromptSubmit` | Spawns `caffeinate -imsu -w <claude_pid>`; records its PID; optionally flips `pmset -b disablesleep 1`. |
| `Stop` | Kills the caffeinate for this session; restores `pmset disablesleep 0`. |
| `SessionStart` | Safety reset (in case a prior session crashed with `disablesleep` still on). |
| `SessionEnd` | Cleans up any leftover caffeinate / pmset state for the ended session. |

State per session is tracked in `/tmp/nosleep-claude/<session_id>.cpid` and `.lid`. Recent activity is logged to `/tmp/nosleep-claude/nosleep-claude.log`.

## License

MIT — see [LICENSE](LICENSE).
