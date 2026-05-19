# nosleep-claude

Keep your Mac awake while the Claude Code CLI is running. Including when the lid is closed.

A tiny LaunchAgent polls for the `claude` process every few seconds. When it sees one, it holds a `caffeinate -dimsu` child to block system sleep. When Claude exits, sleep returns to normal. With an opt-in sudoers rule, it also suppresses clamshell sleep on battery so closing the lid doesn't kill long-running agents.

## Install (Homebrew)

```sh
brew install fabiangenell/tap/nosleep-claude
brew services start nosleep-claude
sudo nosleep-claude install-sudoers   # optional: lid-closed support on battery
```

Check it's working:

```sh
nosleep-claude status
```

## Install (from source)

```sh
git clone https://github.com/FabianGenell/nosleep-claude.git
cd nosleep-claude
./install.sh
```

## What it does (and doesn't)

While Claude is running:

- ✅ Lid closed on battery → stays awake (requires sudoers rule)
- ✅ Lid closed on AC → stays awake
- ✅ No input for hours → stays awake
- ✅ You log out and back in → daemon auto-resumes via LaunchAgent

What this *cannot* do: survive a shutdown, restart, dead battery, or kernel panic. Once the OS goes down, Claude goes with it. This tool prevents *automatic* sleep — it doesn't checkpoint your process.

## Uninstall

```sh
brew services stop nosleep-claude
sudo nosleep-claude uninstall-sudoers
brew uninstall nosleep-claude
```

Or from a source install: `./uninstall.sh`.

## How it works

- LaunchAgent runs `nosleep-claude` (the daemon) at login and keeps it alive.
- The daemon polls `pgrep -x claude` every 5 seconds (configurable via `NOSLEEP_CLAUDE_INTERVAL`).
- When Claude appears, it spawns `caffeinate -dimsu` (blocks display, idle, disk-idle, and system sleep, declares user activity).
- If the sudoers rule is installed, it also runs `sudo -n pmset -b disablesleep 1` to prevent clamshell sleep on battery.
- When Claude exits, the daemon kills caffeinate and re-enables `disablesleep`. Normal Energy Saver rules resume.

The sudoers rule is scoped to exactly `pmset -b disablesleep *` for your user — it can't be used to run other commands as root.

## License

MIT — see [LICENSE](LICENSE).
