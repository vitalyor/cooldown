# How Cooldown is built

**English** · [Русский](ARCHITECTURE.ru.md)

A Swift package, SwiftUI + AppKit, no third-party dependencies. The window is a glass panel
(`NSGlassEffectView`) under the menu bar icon.

## Modules

| Folder | What's inside |
|---|---|
| `Core/` | `AppModel` (state, timers), `AgentActivity` (who is working, waiting, finished), stores (`HistoryStore`, `DailyLog`, `TurnLog`, `EventLog`), forecast and pace, hooks, file watching |
| `Codex/` | limits via `codex app-server`, history from session files, the conversation index (`state_*.sqlite`), the finish watcher, deferred tasks |
| `Claude/` | limits (`/usage`, status line, Claude Desktop), the Claude Desktop window via Accessibility, Claude Code sessions |
| `AutoResume/` | Codex auto-continue: the app's local socket (follower only), the decision policy, the send ledger, the per-task watcher |
| `UI/` | the panel, tabs, cards, settings, the menu bar icon |
| `Core/PhoneLink*` | the iPhone link on the Mac: cards and state out, commands in (see [LINK.md](LINK.md)) |
| `Core/CodexLink`, `Core/AgentRestart` | noticing that Codex stopped answering Cooldown; a safe restart of Codex or Claude |
| `Sources/CooldownLink/` | the end-to-end encrypted link shared by the Mac and the iPhone app |

## One coordinator for events

Every source reports to `AgentActivity`: Codex session files, hooks, the Claude Desktop window.
It decides what to show: the same end of work seen by two sources is announced once; short
turns are not announced; duration and the share of the limit are counted from the start of the turn.

## Claude limits

Several sources are merged by one rule (`ClaudeLimits.merge`): for each window the current one is
taken (the latest reset time), and among readings of that window the highest wins (usage only grows
within a window). Readings more than 20 minutes older than the freshest are ignored.

## Keeping resource use low

- **Events instead of polling.** Session folders are watched with FSEvents; the hook file with a
  dispatch source (`Core/FileWatch.swift`). Timers remain only as a safety net and run with tolerance,
  so macOS can group wake-ups.
- **External programs only when needed.** While Codex works, its limits come from its own files and
  `codex app-server` is not started. `claude /usage` follows Claude: every minute while it works,
  then a pause that grows by half a minute for each quiet minute up to five, every 15 minutes after
  half an hour of quiet (30 with the screen locked), every 2 minutes around a reset, and not at all
  while Claude Code's status line brings fresh numbers.
- **Auto-continue reacts, it does not poll.** A watched task is looked at when its session file
  reports an ended or failed turn, on Codex hooks, when the Codex app starts or quits and when the
  Mac wakes; while waiting for the limit, a wall-clock timer fires exactly at the reset (+15 s). A
  slow heartbeat only catches what no event reported. It runs inside Cooldown, with no extra
  processes; `codex app-server` is started only to read the limits at that moment.
- **The Claude Desktop window.** Usually only the chat address and the message box are read (a few
  dozen elements, one request per element); the whole window only when something changed or once a
  minute. All of it off the main thread.
- **Drawing.** The light on the menu bar line is a Core Animation animation; the image is not redrawn.
  The menu bar icon and frequent "still working" signals from agents don't redraw the window.
  A hidden window polls nothing.
- **History** is read in pieces as files grow; read positions survive Codex moving files between folders.

## Diagnostics

```sh
Cooldown --claude-usage            # what is read from /usage
Cooldown --hooks status            # hook state (install / uninstall)
Cooldown --menu-icon out.png       # the menu bar icon in different states
Cooldown --render --out out.png --provider codex --tab stats   # the window as a picture
Cooldown --showcase --demo 1 --tab limits --clean   # the real window on demo data, for screenshots
Cooldown --snapshot out.png --tab tasks --provider claude   # the real window with real data, as on screen
Cooldown --render --card request --dark   # one card; --render --menu for the menu bar picture
Cooldown --selftest                       # built-in checks
scripts/check-all.sh                      # build, self-test and unit tests
scripts/icon-preview.sh                   # every look of the app icon
```

What the sources did and why a card was or wasn't shown is in
`~/Library/Application Support/Cooldown/activity.log`.

## Localization

Interface strings are written in Russian in the code and wrapped in `L("…")`; the Russian text is the key.
`L(key, args…)` formats with `%@` placeholders in the app's locale. Plural words are keys of the form
`"one|few|many"`; each translation has as many forms as its language needs, and `AppLanguage.pluralIndex`
picks one.

Translations live in `Resources/Localization/src/<lang>.json` (key → text). To add or change strings:

```sh
python3 scripts/l10n_wrap.py keys     # list every key in the code
python3 scripts/l10n_build.py         # check coverage, placeholders and plural forms, write *.lproj
```

`l10n_build.py` must report `problems: 0` before a release. `build.sh` copies the `.lproj` folders into the app.
Check a language without switching macOS: `Cooldown --settings-window general -AppleLanguages '(de)'`.
