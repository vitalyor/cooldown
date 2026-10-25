# Codex auto-continue — functional specification

Written for a clean-room implementation. It says **what** Cooldown must do and **which facts about
Codex** it relies on. It deliberately contains no code and no wording from any other project.

## 0. Rules for the implementer

- Do not open, search or read: any folder named `codex-auto-resume` (in particular
  `~/Downloads/dev/cooldown/reference/`), `~/.codex-auto-resume`, any file under
  `Resources/ThirdParty`, `Resources/Localization` (the string catalogue), and the git history
  of `Sources/Cooldown/AutoResume/` before commit `de33e0c` (no `git log -p`, `git show`, `git
  diff`, `git blame` on those paths, no checking out older commits).
- Do not search the web for other Codex auto-resume / auto-continue tools or their code.
- Allowed: this document, every other file of Cooldown in the working tree, Apple
  documentation, and observing the Codex app and `codex app-server` directly on this Mac.
- Write everything yourself: structure, names of internal types, algorithms, comments, strings.
- Keep a short log of what you did and what you looked at in `docs/clean-room/implementation-log.md`.

## 1. What the feature is

The person picks a Codex conversation in Cooldown (Tasks tab) and turns on auto-continue for it.
When the conversation's current turn fails because the account's usage limit ran out, Cooldown
waits until the limit is really available again and then starts the next turn in the **same
conversation** with one short continuation message. It never approves anything, never answers
questions, never touches other conversations, and never sends twice for the same stopped turn.

## 2. Interface the rest of Cooldown already uses

These names and shapes are used outside the feature and must exist (you may change internals and
add members; if you rename something, update the call sites).

- `struct CodexConversation: Identifiable, Equatable` — `id: String`, `title: String`,
  `cwd: String?`, `updatedAt: Date?`, `archived: Bool`; initialisers
  `init(id:title:cwd:updatedAt:archived:)` and `init(id:name:preview:cwd:updatedAt:archived:)`
  (title = first non-empty of name/preview, trimmed, at most 120 characters, else
  `L("Без названия")`). Used by `CodexThreadIndex`, `AppModel`, `Demo`, `TasksTab`.
- `struct ResumeWatch: Identifiable, Equatable` — `threadId`, `enabled`, `maxResumes`, `status`
  (see §6), `reason` (one human sentence), `updated: Date`, `attempts: Int`; `id == threadId`.
- `struct ResumeCheck: Equatable` — `threadId`, `title: String?`, `taskState: String` (see §6),
  `canMonitor: Bool`, `reason: String`, `model: String?`.
- `enum ResumeError: LocalizedError` with `case refused(String)` and
  `static func friendly(_ error: Error) -> String`. `ClaudeAsks` and `ClaudeDesktopWatcher` throw
  `ResumeError.refused`.
- `enum ResumeStatus { static func taskStateTitle(_ state: String) -> String }`.
- `AutoResume.shared` with: `start()`, `onChange: (([ResumeWatch]) -> Void)?` (main actor, called
  on every change of any watch), `watches() async -> [ResumeWatch]`,
  `conversations() async throws -> [CodexConversation]` (use `CodexThreadIndex.conversations()`
  first, the official list (§4) only if that returns nil), `check(_ id:) async throws ->
  ResumeCheck`, `start(_ id:, maxResumes:) async throws`, `stop(_ id:) async`,
  `isWatched(_ id:) -> Bool` (cheap, any thread), `poke(_ id:, after:)`, `pokeAll(after:)`,
  and `static func inspect(_ id:) throws -> ResumeCheck` (used by the `--resume-check` flag).
- `enum CodexApp` with `bundleId`, `url: URL?`, `isRunning`, `checkVersion()` (throws if not
  installed or too old), `open()`, `open(thread:)`.
- An IPC client used by `CodexRequests.swift` (request cards, already written, keep it working)
  and by `Diagnostics`: create with a timeout, `open()`, `close()`, `discoverOwner(_ thread:) ->
  String`, `setFollowing(_ thread:, owner:, _ on: Bool)`, `answer(_ method:, params:)` (request
  sent to the owner, must come back with `result.ok == true`), `onBroadcast` callback for every
  broadcast received, `descriptor` (socket fd for `poll`), `read(deadline:)` (reads and handles
  one frame). Read `CodexRequests.swift` to see exactly how it is used.
- `enum JSON` helpers used by `CodexRequests` and `ClaudeAsks`: `isNull`, `isBool` (true only
  for real JSON booleans, not 0/1 numbers), `bool` (nil unless a real boolean), `number`,
  `truthy`, `nonEmptyString`, `canonical(_:) -> Data?` (stable serialisation with sorted keys).
- A self-test entry point called from `Core/SelfTest.swift` (`… .run() -> [String]`, the list of
  failed case names) and a valid conversation id constant used there (`.thread`). Rename freely
  and update `SelfTest.swift`.
- `CodexPaths.home` (the Codex home folder), `CodexPaths.binary(override:)`, `Settings.codexPath`,
  `Settings.appSupport`, `CodexThreadIndex.isArchived(id:)`, `CodexThreadIndex.thread(id:)`,
  `CodexError`, `Num` already exist elsewhere in Cooldown.

## 3. The Codex desktop app's local protocol (facts)

Observed behaviour of the Codex app (bundle id `com.openai.codex`; it may be installed as
`/Applications/ChatGPT.app` or `/Applications/Codex.app`). Builds older than `CFBundleVersion`
20770 are not supported.

- Deep link: `codex://threads/<lowercase uuid>` opens a conversation. Opening it with
  `NSWorkspace` and `activates = false` loads it in the background.
- Socket: a Unix stream socket at `<Codex home>/ipc/ipc.sock`. Before connecting, require that the
  folder is a real directory and the socket a real socket, both owned by the current user and not
  accessible by group/others; otherwise refuse (do not change permissions).
- Framing: each message is a 4-byte **little-endian** length followed by that many bytes of UTF-8
  JSON (one object). Reject length 0 or above 32 MiB.
- Kinds of messages (`type` field):
  - `request`: `requestId` (a new lowercase UUID), `sourceClientId`, `method`, `params`,
    `version` (number), `timeoutMs`, optional `targetClientId`.
  - `response`: `requestId`, `resultType` (`"success"` or an error), `error` (string),
    `method`, and the payload (`result`, or top-level fields for some methods).
  - `broadcast`: `method`, `params`, `sourceClientId`, `version`, optional `targetClientIds`.
  - `client-discovery-request`: every client must answer with
    `{"type":"client-discovery-response","requestId":…,"response":{"canHandle":false}}`.
    Cooldown must always say it cannot handle.
  - An incoming `request` addressed to Cooldown must be answered with a `response` of
    `resultType` `"error"` — Cooldown never handles requests (in particular never approvals).
- Handshake: request `initialize`, version 0, params `{"clientType": "cooldown"}`; the reply's
  `result.clientId` is Cooldown's client id for `sourceClientId` from then on.
- Which window owns a conversation: request `thread-owner-discovery`, version 1, params
  `{"hostId":"local","conversationId":<id>}`; success carries `handledByClientId` at the top
  level of the response. An error `"no-client-found"` means the conversation is not loaded in any
  window right now (temporary, not a failure).
- Getting the state: send broadcast `thread-stream-following-changed`, version 1,
  `targetClientIds: [owner]`, params `{"hostId":"local","conversationId":<id>,"following":true}`.
  The owner then broadcasts `thread-stream-state-changed` with `version` 11 and params
  `{"conversationId","hostId":"local","change":{…}}`, `sourceClientId` = owner. `change.type` is
  `"snapshot"` (full state in `change.conversationState`) or `"patches"` (incremental). Only
  trust snapshots from the owner for the conversation asked about; treat any patch as "the state
  you hold is no longer current". Unknown `version` or `change.type` → refuse. Switching
  following off and on again produces a fresh snapshot.
- Starting a turn: request `thread-follower-start-turn`, version 2, `targetClientId` = owner,
  params `{"conversationId":<id>,"turnStart":{"request":{"threadId":<id>,
  "clientUserMessageId":<uuid you chose>,"input":[{"type":"text","text":<message>,
  "text_elements":[]}]}}}`. On success the id of the new turn is at `result.result.turn.id`;
  anything else means the outcome is unknown.
- Answering a pending request of a conversation (used by request cards) uses
  `thread-follower-…` methods sent to the owner; see `CodexRequests.swift`.

### Conversation state fields that matter

- `id`, `hostId` (`"local"` for this Mac), `cwd`, `title`, `latestModel`.
- Persistence: `ephemeral: false` means a normal saved conversation; newer builds may omit the
  flag and instead have a non-empty `rolloutPath`. Anything else: treat as not supported.
- `resumeState`: `"resumed"` once the conversation is fully loaded in the window; other values
  mean it is still loading.
- `requests`: array of things the conversation waits for (approvals, questions, inputs).
  Known harmless leftover: a request with `method` `"item/tool/call"`, params `namespace`
  `"codex_app"`, `tool` `"setup_codex_context_picker"`, same `threadId`, whose `turnId` belongs
  to an **older, interrupted** turn of the same conversation (not the latest one). Such a leftover
  must not count as "waiting for the person"; nothing should be answered or removed.
- `threadGoalResumeConfirmation` (truthy = the app asks the person to confirm),
  `threadGoal` (null, or an object whose `status` is `"active"` or something else),
  `queuedFollowUps` (truthy = the person queued a message).
- `threadRuntimeStatus.type`: `"active"` (running; `activeFlags` truthy = blocked on something),
  `"idle"`, `"systemError"` (a usage-limit failure appears like this), others = transitional.
- Turns: either `turns` (array, last = latest), or `turnHistory` with `kind: "canonical"`:
  `history.islands` (array; the last island is the newest), each island has `entries`
  (array of `{value: <key>}`) and `newerBoundary.status`; `"exhausted"` means nothing newer
  exists. `history.entitiesByKey[<key>]` is the turn. Only trust the newest turn when the newest
  island's boundary is `"exhausted"`.
- A turn: `turnId`, `status` (`"inProgress"`, `"completed"`, `"interrupted"`, `"failed"`),
  `error.codexErrorInfo` — the value `"usageLimitExceeded"` (also seen as
  `"UsageLimitExceeded"`) is the only evidence of a usage-limit failure. Never infer it from text.
- Work settings that must not change between deciding and sending: `cwd`, `latestModel`,
  `latestReasoningEffort`, `latestCollaborationMode`, `currentPermissions`,
  `latestThreadSettings`, plus the goal, requests, queued follow-ups, runtime status,
  `resumeState` and the latest turn.

## 4. `codex app-server` (official, read-only use)

Run `<codex binary> app-server --stdio` with `CODEX_HOME` set to the Codex home. Newline-delimited
JSON-RPC: send `{"id":1,"method":"initialize","params":{"clientInfo":{"name":"cooldown",
"version":"1.0"}}}`, then the notification `{"method":"initialized"}`. Replies carry the same `id`
and `result` or `error`; ignore notifications. Cooldown may only ever call these three methods:

- `account/rateLimits/read` → `rateLimits` (one bucket) and/or `rateLimitsByLimitId`
  (map; Codex's own bucket key is `"codex"`). A bucket has `primary` and `secondary` windows
  (`usedPercent` 0–100, `resetsAt` Unix seconds, `windowDurationMins`), `rateLimitReachedType`
  (null or e.g. `"rate_limit_reached"`), `spendControlReached`, `individualLimit`, `limitId`.
- `thread/list` with `limit`, `archived` (bool), `sortKey: "updated_at"`, `modelProviders: []`,
  `sourceKinds` (`cli`, `vscode`, `exec`, `appServer`, `subAgent`, `subAgentReview`,
  `subAgentCompact`, `subAgentThreadSpawn`, `subAgentOther`, `unknown`), optional `cursor` →
  `data` (rows with `id`, `name`, `preview`, `cwd`, `updatedAt`) and `nextCursor` (null at the
  end). Read every page; a repeated cursor is an error.
- `thread/read` with `threadId`, `includeTurns: true` → `thread` with `id`, `name`, `preview`,
  `ephemeral`, `turns` (each `id`, `status`, `error`).

## 5. Behaviour

### Turning a watch on
`start(id, maxResumes)` accepts only an exact UUID (store it lowercased). It first runs `check`;
if `canMonitor` is false, refuse with the check's reason. Also refuse when this conversation has an
unconfirmed send on record (§5 "Sending"), or when its used attempts already reach `maxResumes`.
Otherwise the watch is enabled and looked at immediately.

### `check` / `inspect` (read-only)
Archived conversations (`CodexThreadIndex.isArchived`, else the official list with
`archived: true`) → `archived`, cannot be watched. Otherwise, if the app has the conversation
loaded, judge the live state (§5 "Deciding"); if the app is closed or the conversation is not
loaded, judge the saved history from `thread/read`: no turns → `empty`; latest turn completed →
`idle`; interrupted → `interrupted`; in progress → `running` (may watch); failed with the
usage-limit code → `quota_limited` (may watch); other failure → `other_failure`; anything
unclear → `unknown`. Saved history may allow **watching**, never **sending**.

### Deciding (live state only)
From one live snapshot decide one of: *send*, *wait*, *stop*, with a task state and a reason.
- Not local, or not a persistent conversation → stop (`unsupported`).
- Still loading → wait (`connecting`).
- Requests present (other than the known leftover), a confirmation asked, a goal that exists but
  is not active, or a queued user message → stop (`needs_attention`). Missing `requests` → stop.
- Runtime `active` → wait (`running`), unless `activeFlags` is truthy → stop (`needs_attention`).
- Runtime other than `idle`/`systemError` → wait (`connecting`). Missing runtime → stop.
- Latest turn unclear (see §3) or without an id → stop.
- Latest turn: in progress → wait (`running`); completed → wait (`running`) if the goal is
  active, else stop (`idle`); interrupted → stop (`interrupted`); failed with the usage-limit code
  → **send** (`quota_limited`); any other failure → stop (`other_failure`).

### Waiting for the limit
"Send" is only a candidate. Before sending, the limit must be confirmed available by a **fresh**
`account/rateLimits/read` — never by the clock alone:
- Use the `"codex"` bucket (or the single `rateLimits` bucket). If the map holds other buckets
  and it is unclear which one applies → cannot decide (blocked).
- Spend control reached or an individual limit present, or a "reached" type other than the normal
  window limit → blocked (needs the person).
- Missing primary window, or any window with missing/invalid fields → blocked.
- Any window at 100% → not yet: look again right after the latest such window resets (add a few
  seconds; at least a minute from now).
- A window whose reset time is already in the past but still shows < 100% → data is stale, look
  again in about a minute. Still flagged as reached → look again in about a minute.
- Otherwise available.
While waiting, the watch keeps looking at the conversation (if the person continues it themselves
or something changes, the watch reacts). Wake exactly at the reset time (wall clock, survives
sleep), not by frequent polling.

### Sending
- Each failed turn gets at most **one** continuation, ever. Count attempts per conversation; when
  they reach `maxResumes`, stop (`budget`).
- Remember the work-relevant part of the state (§3 "Work settings…") at the first "send"
  decision; if it differs at a later look while still waiting → stop (`changed`).
- Write the intent to send (conversation, failed turn id, a new message UUID) to durable storage
  **before** sending. If the watch was switched off by then, do not send.
- Right before sending: verify the app version again, take a **fresh** snapshot, re-decide (must
  still be "send") and compare with the remembered state (must be identical), make sure no new
  state broadcasts arrived since that snapshot (drain what is already waiting without trusting
  it; if the stream keeps moving, give up for now), and check once more that the watch is still
  enabled and the recorded intent is still the current one. Then start the turn (§3).
- A confirmed new turn id → record it, status `resumed`. Anything else (error, timeout, missing
  id) → the outcome is **unknown**: status `uncertain`, watch disabled, and this conversation is
  never sent anything automatically again until the person handles it (starting the watch again
  is refused while the unconfirmed record exists).
- If a send for this failed turn is already on record: within about two minutes of sending, keep
  watching (the app may not have updated yet); otherwise stop.

### The continuation message
One short message in the conversation's language of the interface (put it in `L("…")` in Russian).
It must: say the limit is available again; ask to continue the interrupted work in this same
session; ask to first check the current progress and the working folder; forbid repeating steps
already done, widening the scope and bypassing confirmations; ask to say so plainly and stop if the
work is already done or a decision of the person is needed. Write your own wording.

### Connection problems
- App closed, socket missing, conversation not loaded, timeouts → temporary: keep the watch
  (`waiting_connection`, or `waiting_quota` when it was the limits read that failed). Never send
  based on saved history.
- If the conversation is not loaded but the app runs: at most once every 5 minutes, re-check
  eligibility (not archived, saved history still allows watching, watch still enabled) and open it
  in the background with the deep link. If it is no longer eligible → stop.
- Three non-temporary failures in a row → stop (`blocked`); a success resets the count;
  in between show `retrying`.

### Stopping
`stop(id)` must take effect at once, even while a look is in progress (a separate path that
disables the watch in storage; the send path checks the stored flag right before sending).

### Events and timing
React to: `poke(id)` (Cooldown calls it when the conversation's session file or a hook reports
that a turn ended or asked for something), `pokeAll` (limits may have reset; Mac woke; Codex app
launched — give it a few seconds to open its socket; Codex app quit). Otherwise look again: at the
limit reset while waiting for it (at most 10 minutes apart), ~20 s after a send, ~30 s while
retrying, every few minutes while a turn just runs, rarely (minutes) while the app is closed.
Timers on the wall clock. All watching runs on one background serial queue; publish changes to
`onChange` on the main thread.

### Several Cooldown copies
Only one process may watch a given conversation: hold an exclusive lock per conversation while
watching (e.g. `flock` on a file in the feature's storage folder); if it cannot be taken → that
watch is `blocked`.

### Storage
Your own design, in `Settings.appSupport/<a new folder name>`, folder 0700 and files 0600, owned by
the user, no symlinks, crash-safe (a send intent must survive a crash between writing and sending).
Keep: watches (`threadId`, enabled, maxResumes, status, reason, updated) and send records
(conversation, failed turn, message id, state: pending / confirmed, new turn id, time).
**Migration, once:** the previous Cooldown version kept its data in
`Settings.appSupport/AutoResume/state.sqlite3`, table `watches` with columns `thread_id`,
`enabled`, `max_resumes`. Import the rows with `enabled = 1` as enabled watches (status
`starting`) and then never read that file again. Do not import anything else, and do not read
`~/.codex-auto-resume`.

## 6. Identifiers the UI understands

Watch `status` (shown by `TaskStatus.title` in `Core/AppModel.swift`; keep these exact strings):
`starting`, `watching` (a turn is running), `waiting_quota`, `waiting_connection`,
`needs_attention`, `resumed`, `stopped`, `paused` (switched off by the person), `uncertain`,
`blocked`, `budget`, `changed`, `retrying`. `TaskStatus.needsAttention` treats
`needs_attention`, `blocked`, `uncertain`, `changed` as needing the person.

Task state (`ResumeCheck.taskState`, `ResumeStatus.taskStateTitle`): `running`, `quota_limited`,
`needs_attention`, `idle`, `empty`, `interrupted`, `other_failure`, `unsupported`, `archived`,
`connecting`, `unknown`. `canMonitor` is true only for `running` and `quota_limited`.

## 7. Strings, style, checks

- Every user-facing sentence in Russian through `L("…")`, short and plain (see other Cooldown
  files for the tone). Internal identifiers stay ASCII. Translations are done separately.
- Comments in English, explaining *why*. Follow the code style of the surrounding files.
- Self-test: write your own cases for deciding, the limits check, the leftover request, the
  "never twice" rule and the unknown-outcome rule, without talking to the real app.
- Build with `./build.sh` (see below), run `build/Cooldown.app/Contents/MacOS/Cooldown --selftest`
  (must print `self-test: all passed`).
