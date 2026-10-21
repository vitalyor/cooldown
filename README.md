# Cooldown

**English** · [Русский](README.ru.md)

**A macOS menu bar app for people who work with Codex and Claude all day: limits at a glance,
what each agent is doing, a card when work is done, and continuing after a limit resets.**
Everything runs locally on your Mac.

> Unofficial project, not affiliated with OpenAI or Anthropic. Codex and Claude are trademarks of their owners.
> The app's interface is currently in Russian.

## Features

**Limits**
- The 5-hour and weekly limits of Codex and Claude in the menu bar: a number and a bar coloured by what is left.
- Forecast: when the limit runs out at the current pace, whether it lasts until the reset, how much you can spend per day.
- Comparison with your usual pace and with previous weeks.

**What the agents are doing**
- While an agent works, a soft light runs along its bar in the menu bar; an orange dot means it is waiting for your decision.
- Cards under the menu bar icon: "finished" (with the start of the answer, time spent and share of the limit),
  "waiting for your decision", "limit is back", "silent for 15 minutes", "stopped with an error".
- Sources: Codex session files, Codex and Claude Code hooks (optional), the Claude Desktop window
  via Accessibility.

**Continuing after a reset**
- Codex: a task that hit the limit continues by itself (via [Codex Auto Resume](https://github.com/progressrdx/codex-auto-resume)).
- Claude Code: a session continues by itself via `claude --resume`.
- Claude Desktop chats: Cooldown finds the chat and sends the continuation — only when you press the button.
- Deferred Codex tasks: start as soon as Codex has limit again.

**Statistics**
- Tokens, projects, models and the approximate API price of the same work.
- "Year of work" — a day-by-day grid, like on GitHub.
- The most expensive tasks, a weekly summary, CSV export.

## Requirements

- macOS 26 (Tahoe) or later.
- Command Line Tools (`xcode-select --install`); Xcode is not required.
- Codex and/or Claude Code / Claude Desktop — whichever you use.

## Install

Download the latest **Cooldown-x.y.z.dmg** from [Releases](https://github.com/vitalyor/cooldown/releases/latest),
open it and drag Cooldown to Applications.

Cooldown is not notarized by Apple, so on first launch macOS says it cannot verify the developer.
Open **System Settings → Privacy & Security** and press **Open Anyway**
(or run `xattr -dr com.apple.quarantine /Applications/Cooldown.app`).

## Build and run

```sh
./build.sh            # build build/Cooldown.app
./build.sh --install  # build, copy to /Applications and launch
```

Optional but handy — a stable local signing identity, so macOS keeps the permissions it granted
across builds:

```sh
scripts/make_signing_identity.sh
```

Building your own version next to the original? Give it its own bundle id so settings and
permissions don't mix: `echo 'COOLDOWN_BUNDLE_ID=com.yourname.cooldown' > local.env`.

To bundle Codex auto-continue into the app, put
[codex-auto-resume](https://github.com/progressrdx/codex-auto-resume) next to the project folder
(`../codex-auto-resume`) or set `RELAY_SRC` before building.

## First launch

Cooldown shows what is missing under Settings → Readiness:
- **Notifications** — for cards when you are away from the Mac.
- **Accessibility** — to see that Claude Desktop is writing an answer, and to continue chats.
- **Agent hooks** (optional) — instant events from Codex and Claude Code. Codex asks once to
  approve the new hooks.

## Privacy

Cooldown sends nothing to servers of its own — there are none. Details: [docs/PRIVACY.md](docs/PRIVACY.md).

## How it works

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — data sources, modules, and how Cooldown keeps its
resource use low. Ideas behind the features: [IDEAS.md](IDEAS.md).

## Thanks

- [Codex Auto Resume](https://github.com/progressrdx/codex-auto-resume) by progressrdx (MIT) —
  auto-continue for Codex tasks.

## License

[MIT](LICENSE). Codex Auto Resume, bundled into the build, is distributed under its own MIT license.
