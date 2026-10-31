# What Cooldown reads and where it connects

**English** · [Русский](PRIVACY.ru.md)

Cooldown runs on your Mac. It has no analytics or telemetry. It connects to the relay only if you turn on Cooldown for iPhone (`cooldown.nolim.cloud` by default), and checks GitHub for updates unless you turn that off.

## Reads (read-only)

| What | Why |
|---|---|
| `~/.codex/sessions`, `~/.codex/archived_sessions` | Codex tokens, limits, when work starts and ends |
| `~/.codex/state_*.sqlite` (opened read-only) | the list of Codex conversations and where their files are |
| `~/.codex/session_index.jsonl` | conversation names |
| `~/.claude/projects` | Claude Code tokens |
| `~/Library/Application Support/Claude/plan-usage-history.json` | the limit history Claude Desktop keeps itself |
| `~/Library/Application Support/Claude/claude-code-sessions` | names of Claude Code sessions started from Claude Desktop |
| The Claude Desktop window, via Accessibility | which chat is open, whether Claude is writing an answer, the first words of the answer |

## Runs

- `codex app-server` — the `account/rateLimits/read` request (Codex's official client); for auto-continue also `thread/list` and `thread/read` — read-only.
- `claude /usage` — Claude Code's limits screen (official client). Hooks, the status line and Claude
  Code's background traffic are turned off for this run.
- `codex exec` — only tasks you deferred yourself.

## Changes (only with your consent)

- `~/.claude/settings.json` — Cooldown's status line and hooks, if you turned them on. A copy is saved
  next to the file before writing. Other tools' entries (Coucou, for example) are left untouched.
- `~/.codex/hooks.json` — Cooldown's hooks, if you turned them on. Codex asks you to approve them.
- `~/Library/Application Support/Claude/claude_desktop_config.json` — an optional local MCP bridge,
  only if you turn it on in Settings. Claude's other MCP servers are kept; a copy is saved first.

Claude Code's permission hook is the exception: while you are away from the app running that
session, it waits for the answer you press on Cooldown's card (up to an hour) and passes it on;
at that app, or with Cooldown not running, it returns at once and Claude Code asks as usual.

A Cooldown hook only appends one line to
`~/Library/Application Support/Cooldown/hook-events.jsonl` and exits. The file is rotated at 8 MB.
The MCP bridge only appends events Claude chose to report to `mcp-events.jsonl`.

## Sends

- Answers to agents' requests (permissions, questions) — **only the button you press on a card**: to Codex through its app's follower commands, to Claude Code through its permission hook, to a Claude Desktop chat by pressing the same button there. Before sending, Cooldown checks that the very same request is still waiting.
- Into a Codex conversation you chose — one continuation message per turn stopped by the limit, after it resets. Through the Codex app's local socket (`~/.codex/ipc/ipc.sock`), as a follower only: Cooldown approves nothing and answers none of the app's requests. The send ledger lives in `~/Library/Application Support/Cooldown/AutoResume/` (yours only); an unconfirmed send is never repeated.

- To your iPhone — only if you turned on Cooldown for iPhone and paired a phone: cards, chat names,
  answers and the delivery log are encrypted on the Mac and opened only on your phone; the relay
  (`cooldown.nolim.cloud` by default) passes them on without reading them. For the Live Activity it
  sees general lines ("Claude is working"), button labels and reset times. Details: [LINK.md](LINK.md).

Cooldown does not use Claude Code's sign-in (the token in the Keychain): Anthropic allows it only in
its own apps.

## Stores

Everything in `~/Library/Application Support/Cooldown/`: limit and token history (45 days), daily
totals, events, chosen chats, diagnostic records (`activity.log`, up to 2 MB in two files; with an iPhone
paired, also `phone-delivery.log` — times and ids only, no text).
