# Codex auto-continue — clean-room implementation log

## What I read
- `docs/clean-room/auto-continue-spec.md` (the only source of requirements), in full.
- Cooldown's own working tree: `AutoResume/CodexRequests.swift` (IPC client usage), `Core/SelfTest.swift`,
  `App.swift` (`--resume-check`, `--selftest`), `Core/AppModel.swift` (watches, `TaskStatus`), `Core/Demo.swift`,
  `UI/TasksTab.swift`, `Core/Diagnostics.swift`, `Codex/CodexThreadIndex.swift`, `Codex/CodexLimits.swift`
  (`CodexPaths`, `CodexError`, `CodexAppServer`), `Core/Settings.swift`, `Core/Localization.swift`, `Core/Models.swift`
  (`Num`), `Core/Hooks.swift`, `Codex/CodexFinishWatcher.swift` (call sites of `poke`), `build.sh`, `Package.swift`.
- Not opened: anything named codex-auto-resume, `~/Downloads/dev/cooldown/reference/`, `~/.codex-auto-resume`,
  `Resources/ThirdParty`, `Resources/Localization`, git history of `Sources/Cooldown/AutoResume` before de33e0c.
  No web searches.

## Observed on this Mac (read-only)
- Codex app: `/Applications/ChatGPT.app`, bundle `com.openai.codex`, build 21828. `~/.codex/ipc` is 0700, socket 0600.
- With a small throwaway Python probe (in /tmp, not in the repo): initialize → `result.clientId`; owner discovery for a
  loaded conversation succeeds at once; for a not-loaded one the `no-client-found` error arrives after ~10 s no matter
  what `timeoutMs` says. So owner discovery waits at least 13 s (this also keeps the request cards' loop from treating
  "not loaded" as a timeout).
- Following → one `thread-stream-state-changed` v11 snapshot from the owner. The snapshot has both `turns` (empty) and
  `turnHistory` (canonical, filled). Decision: `turnHistory` wins when present; `turns` only when it is absent.
- `codex app-server`: `account/rateLimits/read` (`rateLimits` + `rateLimitsByLimitId.codex`), `thread/read` with turns,
  `thread/list` — shapes as in the spec.
- The app's own bundle (`app.asar`, grepped for the method names only) lists the protocol versions: start-turn 2, the
  `thread-follower-*` answer commands 1, replies `{result:{ok:true}}`. Used for `answer()`.
- No session file on this Mac contains a usage-limit failure, so the "send" path was not seen live.

## Design
- `CodexIPC.swift`: `JSON` helpers, `CodexApp`, `CodexIPCError`, `CodexIPCConnection` (framing, socket safety
  checks, quiet client: says canHandle=false, refuses every request, `snapshot()` by follow off/on).
- `CodexOfficial.swift`: app-server session limited to the three read-only methods.
- `ResumeRules.swift`: pure decisions — `decide` (live), `judgeHistory` (watch only), `judgeLimits`, `fingerprint`,
  leftover picker, `gate` (never twice / unknown outcome / budget), `startRefusal`, the continuation text.
- `ResumeStore.swift`: `Settings.appSupport/CodexContinue/state.json` (0700/0600, O_NOFOLLOW, owner checked),
  read-modify-write under a store-wide `flock` (two Cooldown copies share the folder), atomic fsynced rename;
  per-conversation `flock` while watching; one-time import of enabled rows from `AutoResume/state.sqlite3`.
- `AutoResume.swift`: the engine on one serial queue, wall-clock timers, pokes, Mac wake / Codex launch / quit.
  Send path: durable pending intent → version check → fresh snapshot with following kept on → drain (any state
  broadcast = moving, give up) → re-decide + identical fingerprint → stored flag and intent re-checked → start turn.
  Confirmed turn id → `resumed`; anything else after the request went out → `uncertain`, watch off, record stays
  pending. Failures before the request goes out withdraw the intent (nothing was sent).
- `ResumeTypes.swift`: the interface types of spec §2. `ResumeSelfTest.swift`: self-test cases.

## Interpretations (the spec left these open)
- `JSON.truthy`: empty arrays/objects count as "nothing" (an empty `queuedFollowUps` or `activeFlags` list).
- Stop outcomes: `needs_attention` keeps the watch on (slow looks, matches the demo); idle/interrupted/empty/archived
  → `stopped` and off; other failure / unsupported → `blocked` and off; unclear data counts as a non-temporary
  failure (`retrying`, then `blocked` after three).
- A send already on record for the same failed turn more than ~2 min ago → `needs_attention`, nothing sent.
- Attempts are counted per conversation across restarts of the watch (every send record counts).
- An unconfirmed send blocks `start` until fresh data shows a newer turn than the one it answered (the person took
  over); then the record is kept as a used attempt marked `unconfirmed`. On launch, pending records turn their
  watches `uncertain` and off.
- A watch held by another Cooldown copy is shown as `blocked` in this copy only; the stored data is left alone.

## Verification
- `./build.sh` builds; `Cooldown --selftest` → `self-test: all passed`.
- `--resume-check` against the live app (read-only): loaded idle conversation → `idle` from the live snapshot (~40 ms);
  not-loaded conversation → falls back to `thread/read` after the ~10 s discovery; archived conversation → `archived`;
  short id → refused. Nothing was sent to any conversation; `thread-follower-start-turn` was never called.
