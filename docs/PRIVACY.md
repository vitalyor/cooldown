# What Cooldown reads and where it connects

**English** · [Русский](PRIVACY.ru.md)

Cooldown runs on your Mac. The project has no servers, analytics or telemetry.

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

- `codex app-server` — the `account/rateLimits/read` request (Codex's official client).
- `claude /usage` — Claude Code's limits screen (official client). Hooks, the status line and Claude
  Code's background traffic are turned off for this run.
- `codex exec` — only tasks you deferred yourself.
- `claude -p … --resume` — only Claude Code sessions you set to continue yourself.

## Changes (only with your consent)

- `~/.claude/settings.json` — Cooldown's status line and hooks, if you turned them on. A copy is saved
  next to the file before writing. Other tools' entries (Coucou, for example) are left untouched.
- `~/.codex/hooks.json` — Cooldown's hooks, if you turned them on. Codex asks you to approve them.

A Cooldown hook only appends one line to
`~/Library/Application Support/Cooldown/hook-events.jsonl` and exits.

## Sends

- Into a Claude Desktop chat — one continuation message, **only when you press the button**.
- To claude.ai — only if you signed in to claude.ai in Cooldown's settings yourself: reading limits
  and the chat list (at most every 2 and 5 minutes). These are the site's internal endpoints, not an
  official API; automated access is restricted by Anthropic's terms — turn it on deliberately.

Cooldown does not use Claude Code's sign-in (the token in the Keychain): Anthropic allows it only in
its own apps.

## Stores

Everything in `~/Library/Application Support/Cooldown/`: limit and token history (45 days), daily
totals, events, chosen chats, diagnostic records (`activity.log`, up to 256 KB).
