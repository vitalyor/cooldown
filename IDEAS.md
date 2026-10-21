# Ideas

**English** · [Русский](IDEAS.ru.md)

All three ideas below are implemented; kept as a record of the intent.

## 1. Codex and Claude Code hooks
Study thoroughly what hooks can do and add Cooldown's own. Only useful and fast — nothing that slows the agents down.
- Study: events (SessionStart, UserPromptSubmit, Pre/PostToolUse, PermissionRequest, Stop, SubagentStart/Stop, Interrupt, SessionEnd), their input, timeouts, hook approval in Codex (trusted_hash in config.toml), living next to Coucou in ~/.codex/hooks.json and ~/.claude/settings.json.
- Possible uses: an instant "finished" instead of polling files; "waiting for your answer" (PermissionRequest); an exact "working now" for the menu bar indicator; time spent per project.
- Principles: a hook only writes a short event and exits at once (milliseconds); don't get in Coucou's way; turned on in settings; the file watcher stays as a fallback.

## 2. Agent activity indicator in the menu bar
See that a session is working right now. Neat and informative, not a big dot.
Sketches:
- The Codex or Claude icon "breathes" faintly (smooth opacity) while the agent works.
- A thin highlight running along the working agent's limit bar.
- A small number next to the icon when several sessions work.
- A short flash when work is done, or "waiting for an answer" in another colour.
- No animation with Reduce Motion; on hover, a tooltip listing which chats are working.

## 3. A yearly activity map, like on GitHub
A day × week grid for the year, each cell coloured by how much the agents worked. Possibly as a separate tab.
- The day's measure to choose from: tokens, API price, agents' working time, finished tasks.
- A Codex / Claude / both switch; shades in the agent's colour.
- Hovering a cell: date, tokens, ≈$, the day's projects. Clicking: open that day's statistics.
- Under the grid: streak of days in a row, the busiest weekday, the year's total.
- Important: history is kept for 45 days now. Daily totals need to be stored separately and forever (tiny data), and on first launch the past should be collected from whatever Codex and Claude Code files remain on disk.
