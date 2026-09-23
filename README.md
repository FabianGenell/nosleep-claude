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

## Checking it actually works

```sh
nosleep-claude status          # full report, exits 1 if the plugin is not wired up
nosleep-claude status --short  # one line: OK / IDLE / STALE / BROKEN
nosleep-claude logs            # recent hook activity
```

Inside Claude Code the plugin's `bin/` is on PATH, so `nosleep-claude` just works, and `/nosleep-claude` prints the same report. To have it in a normal terminal too, symlink it:

```sh
ln -s ~/.claude/plugins/cache/nosleep-claude/nosleep-claude/*/bin/nosleep-claude ~/.local/bin/nosleep-claude
```

`status` checks the things that fail silently:

- the plugin is enabled and its marketplace declaration in `settings.json` matches the registry (a mismatch makes Claude Code refuse to load the plugin, with no visible error)
- the installed version matches the marketplace source, so local edits that were never reinstalled show up as `STALE`
- hooks have actually fired (`/tmp/nosleep-claude/nosleep-claude.log` and how long ago)
- which sessions hold a live timer and how much of the grace window is left
- the lid-closed sudoers rule and the current `pmset disablesleep` value

## Menu bar indicator

```sh
nosleep-claude menubar install    # builds and starts it
nosleep-claude menubar restart    # rebuild after editing the Swift source
nosleep-claude menubar uninstall
```

A small `NSStatusItem` app (`menubar/NoSleepBar.swift`, ~100KB compiled, no Dock icon) that renders `status --json`: a filled disc with a pulse trace knocked out of it while something is holding this Mac awake, a hollow ring when it will sleep on idle. The glyph carries no text: the time left is in the menu, and in the tooltip. The menu is four things: the state, the Claude sessions holding it (project plus the last thing each was asked, since that's the only way to tell two of them apart), today's totals, and a manual one-hour hold. Everything else is behind Details or in the CLI.

`nosleepbar --preview-menu out.png` renders the menu to light and dark PNGs without opening it, which is how to check its layout when a menu bar manager hides the item.

It reads the same JSON anything else can:

```sh
nosleep-claude status --json
```

`sleep_blocked` deliberately ignores powerd's "prevent sleep while display is on" assertion, which is held the whole time the screen is lit and says nothing about what happens once you walk away.

The awake glyph is drawn by hand (SF Symbols has no knockout disc); `nosleepbar --export-icon out.png` writes it to a file, which is the only way to inspect a template image without the menu bar. `NOSLEEP_GLYPH_SIZE` sets how big it draws (12 to 22 points, 20 by default), and `NOSLEEP_SYMBOL_AWAKE` / `NOSLEEP_SYMBOL_SLEEP` swap either half for a stock symbol, and `menubar install` / `restart` bake whatever is set into the LaunchAgent:

```sh
NOSLEEP_SYMBOL_AWAKE=waveform.path.ecg.rectangle \
NOSLEEP_SYMBOL_SLEEP=minus.rectangle \
nosleep-claude menubar restart
```

`menubar install` builds with `swiftc` (Xcode command line tools) and installs a `net.genell.nosleepbar` LaunchAgent so it comes back at login. If a menu bar manager like Ice or Bartender is running, the icon may land in its hidden section.

## Stats

```sh
nosleep-claude stats           # today / 7 days / 30 days / all time
nosleep-claude stats --json
```

Every prompt, stop and session end appends a row to `~/.local/state/nosleep-claude/events.tsv` (project and the first 90 characters of the prompt, so live sessions can be told apart). Two numbers come out of it:

- **awake**: wall clock the Mac stayed up because of this plugin, as the union of every session's hold window, so two sessions working at once are not counted twice
- **working**: time Claude spent answering, summed per session, which does count both

The runtime state in `/tmp` dies with the boot; this history does not.

## Troubleshooting

**`BROKEN — marketplace declaration in settings.json differs from the registry`**

Claude Code compares `extraKnownMarketplaces` in `settings.json` against `plugins/known_marketplaces.json` and refuses the load on any difference, including fetch-shaping fields like `path` on a `github` source. Nothing surfaces in the UI — the hooks simply never run. Re-register:

```sh
claude plugin marketplace remove nosleep-claude
claude plugin marketplace add <path-or-repo>
claude plugin install nosleep-claude@nosleep-claude
```

**`BROKEN — hooks have never fired since boot`**

The wiring is fine but this Claude Code process started before the plugin loaded. Restart Claude Code.

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

State per session is tracked in `/tmp/nosleep-claude/<session_id>.cpid` and `.lid`. Recent activity is logged to `/tmp/nosleep-claude/nosleep-claude.log`, which is what `nosleep-claude status` reads to tell you whether the hooks are alive.

## License

MIT — see [LICENSE](LICENSE).
