# nosleep-claude

A Claude Code plugin that keeps your Mac awake **while Claude is actively working**, plus a 15-minute grace window after its last activity. Then sleep returns to normal.

No daemon, no LaunchAgent, no polling. Every prompt and tool call (re)starts a self-expiring `caffeinate -t 900`; when Claude stops, the timer restarts one last time and simply runs out. Because sleep prevention always self-expires, nothing can pin the Mac awake for more than the grace window — even if Claude crashes or a hook never fires.

## Install

In Claude Code:

```
/plugin marketplace add FabianGenell/nosleep-claude
/plugin install nosleep-claude@nosleep-claude
```

Then restart Claude Code so the hooks load. That's it — every prompt now blocks system sleep for the duration of Claude's response plus the grace window.

The grace window defaults to 15 minutes. Set `NOSLEEP_GRACE_SECS` in the environment Claude Code runs in to change it.

### Optional: lid-closed support on battery

By default, closing the lid on battery still puts the Mac to sleep (`caffeinate` doesn't override clamshell sleep). To prevent that too:

```sh
sudo ~/.claude/plugins/marketplaces/nosleep-claude/nosleep-claude/bin/nosleep-claude enable-lid-closed
```

(Run `/nosleep-claude` inside Claude to see the exact path on your machine.)

That installs a tightly-scoped passwordless-sudo rule for `pmset -b disablesleep`. After that, lid-closed sleep is suppressed during any active prompt — and re-enabled when Claude finishes.

## Behavior

While Claude is responding (and for 15 minutes after it finishes):

- ✅ No idle sleep, no disk sleep, no system sleep
- ✅ With lid-closed support: lid can close, Claude keeps running
- ✅ Display can still sleep (screen lock still works as expected)

Once the grace window runs out:

- ✅ Mac sleeps normally per your Energy Saver settings, even with the CLI still open at the prompt
- ✅ Battery is not held hostage

When Claude crashes / terminal is killed / Ctrl+C interrupts:

- Every caffeinate carries a `-t` timeout, so the worst case is "awake for one extra grace window", never "awake forever"
- `SessionEnd` kills the timer immediately when a session exits cleanly

## Uninstall

```
/plugin uninstall nosleep-claude
```

To also remove the lid-closed sudoers rule:

```sh
sudo ~/.claude/plugins/.../bin/nosleep-claude disable-lid-closed
```

## How it works

Five hooks in `hooks/hooks.json`:

| Hook | What it does |
|------|--------------|
| `UserPromptSubmit` | Restarts a self-expiring `caffeinate -imsu -t <grace>`; optionally flips `pmset -b disablesleep 1`. |
| `PostToolUse` | Extends the timer while Claude works (throttled to one restart per minute). |
| `Stop` | Restarts the timer once more so the grace window counts from when Claude finished; restores `pmset disablesleep 0`. |
| `SessionStart` | Safety reset (in case a prior session crashed with `disablesleep` still on). |
| `SessionEnd` | Kills the timer and cleans up pmset state for the ended session. |

State per session is tracked in `/tmp/nosleep-claude/<session_id>.cpid` and `.lid`. Recent activity is logged to `/tmp/nosleep-claude/nosleep-claude.log`.

## License

MIT — see [LICENSE](LICENSE).
