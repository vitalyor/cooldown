# Cooldown Link

**English** · [Русский](LINK.ru.md)

How Cooldown on the Mac talks to Cooldown on the iPhone. The Mac is the only side that does
anything: it sends to Codex and Claude, answers requests and runs watches. The iPhone shows what
the Mac reports and sends commands back. The relay in between only passes sealed messages along
and sends pushes through Apple.

```
iPhone ⇄ relay (WebSocket, HTTPS, APNs) ⇄ Mac
```

## What the relay can see

- Device ids, which space (one Mac and its phones) they belong to, when they are online.
- Message sizes and times, and the name of a "keep" slot (`state`).
- Live Activity content: general titles ("Codex is waiting for your decision", "Claude is working"),
  button labels, reset times, how long an agent has worked and how many things wait. iOS gives a
  Live Activity no way to decrypt anything on the device, so this part travels in plain form. It
  never carries chat titles, answers, commands or file paths.

Everything else (cards, their texts and buttons, chat lists, commands, results) is sealed on one
device and opened on the other.

## Keys

Live Activity buttons use fixed, general labels. Questions with custom answer options travel as
encrypted notification cards instead, so their answer text is never sent to the relay in clear text.

- Every device keeps a Curve25519 key-agreement key in its Keychain.
- A Mac and a phone share `key = HKDF-SHA256(ECDH(a, B), salt "cooldown-link-v1",
  info = smaller public key ‖ larger public key, 32 bytes)`.
- A message is sealed with ChaCha20-Poly1305 (CryptoKit `ChaChaPoly`, combined form, random
  nonce). The additional data is `from ‖ "|" ‖ to ‖ "|" ‖ id`, so a sealed box can't be moved to
  another envelope.
- Inside each box are `ts` and `id`. A receiver drops a box older than its `ttl` or with an id it
  has already seen.

## Pairing

1. The Mac registers once (`POST /v1/register`) and gets its space, device id and token.
2. To add a phone the Mac makes a random `code` (16 bytes) and `secret` (32 bytes). It sends only
   the code to the relay (`POST /v1/pair/offer`). The code works once, for 5 minutes.
3. The Mac shows a QR code:
   `cooldown://pair?r=<relay>&c=<code>&s=<secret>&k=<Mac public key>&n=<Mac name>`.
   The secret never reaches the relay.
4. The phone claims the code (`POST /v1/pair/claim`) and sends `hello`: its public key and name
   sealed with `HKDF(secret, info "cooldown-pair")`. It gets its own device id and token.
5. The relay hands `hello` to the Mac. Only a phone that saw the QR code can make a `hello` the Mac
   accepts, so the relay can't slip in a key of its own.

## Relay API

All calls but register, claim and health need `Authorization: Bearer <token>`.

| Call | Who | What |
|---|---|---|
| `POST /v1/register` `{name}` | Mac | New space. Returns `{space, device, token}`. |
| `POST /v1/pair/offer` `{code}` | Mac | Makes a code valid for 5 minutes. |
| `POST /v1/pair/claim` `{code, name, hello}` | phone | Returns `{space, device, token, mac}`. |
| `GET /v1/ws` | both | WebSocket, frames below. |
| `POST /v1/send` envelope | both | For a phone woken in the background. |
| `GET /v1/inbox` | both | Messages waiting for this device, and the kept ones. |
| `POST /v1/got` `{ids}` | both | Confirms messages arrived. |
| `POST /v1/push` `{kind, token, env, activity}` | phone | `kind` is `alert`, `start` or `activity`. |
| `GET /v1/devices` | both | Devices of the space, online state, last seen. |
| `DELETE /v1/devices/{id}` | Mac, or a phone for itself | Unpairs. |
| `GET /v1/health` | anyone | `ok`. |

### WebSocket frames

Every frame is JSON with a type `t`:

- `env`: an envelope (below), both ways.
- `ack` `{id}`: from the relay once it has stored or delivered an envelope.
- `la` `{event, state, alert, stale, dismiss, priority}`: from the Mac, Live Activity push.
- `presence` `{device, online, seen}`: from the relay.
- `paired` `{device, name, hello}`: from the relay to the Mac.
- `unpaired` `{device}`: from the relay.
- `delivered` `{id, device, ms}`: from the relay to the Mac, when a phone confirmed a notification.
- `undelivered` `{id, device}`: from the relay to the Mac, when a phone never confirmed one.
- `error` `{id, code, text}`: from the relay.

### Envelope

```json
{"t":"env","id":"<uuid>","to":"<device>","ttl":600,"keep":"state","box":"<base64>",
 "push":{"collapse":"<opaque>","sound":true,"level":"active"}}
```

- `from` is set by the relay from the token.
- `keep`: instead of queuing, the relay keeps only the latest envelope per sender, receiver and slot.
- `push` (Mac only): also wake the phone with an alert. The push carries a placeholder text and the
  sealed box; the phone's notification extension opens it and shows the real text and buttons.
  `collapse` is an opaque id, so a newer card replaces an older one with the same key.
- `push.remove` `[collapse ids]` sends a silent push that removes those notifications.
- `push.badge`: the number for the app icon (cards waiting for a press).
- The same envelope id again within ten minutes is acknowledged and dropped: a device whose
  connection died before the `ack` sends unacknowledged envelopes again on the next one.
- A message for a device that is offline waits until `ttl` runs out (at most a day, 200 per device,
  1 MB per device and 32 MB for the whole relay; past that it goes out only to a connected device).
- The box carries its own `ttl`, sealed with it. The envelope's `ttl` (and the push's) is set by the
  carrier, so a receiver goes by the sealed one; a box from an older sender without it is believed
  for at most a day.

## Messages inside a box

```json
{"m":"state","id":"…","ts":1761369000, ...}
```

| `m` | From | Fields |
|---|---|---|
| `state` | Mac | `limits`, `agents`, `watches`, `cards`, `mac`, `live` |
| `card` | Mac | `card {key, kind, provider, title, body, actions [{id, title, style, auth, input}], created, expires}` |
| `resolve` | both | `key`, `by`: a card was answered or closed somewhere |
| `cmd` | phone | `id`, `op`, `args` |
| `result` | Mac | `cmd`, `code`, `text`, `chats` |

Button ids (`action`):

- `continue`, `continueChat`, `continueAll`: send "continue" into the chat on the Mac.
- `choice:<id>`: answer an agent's question or permission request. `auth: true` asks for Face ID first
  ("Allow" and typed answers). On a question of several the id names the step (`choice:step1:option:0`): a press
  meant for an earlier question gets `stale` instead of landing on the next one.
- `restart:<provider>` (`auth: true`): restart Codex or Claude on the Mac once it is free (see README).
- `reply` (`input: true`, `auth: true`): a text answer, sent in `args.text`. Only on "finished" cards.
- VPN guard: `guardExit:<remember|once|refuse>:<key>` answers a new-exit card (Face ID for allowing; an answer to
  an older card gets `stale`); `guardPause` (`auth: true`) turns the guard off for an hour; `guardResume` turns it
  back on; `guardCheck` checks the routes now and says whether the agents are still paused.
- `installRelease` (`auth: true`): install the new version of Cooldown on the Mac.

Commands (`op`):

- `card.act` `{key, action, text?}`: press a card button. `key` is the card key, or `#<collapse id>`
  from a Live Activity button (the Lock Screen never sees the real key). The Mac checks the card is
  still open first and answers `stale` if it isn't.
- `chats` `{provider}`: list Codex conversations or Claude chats.
- `watch` `{provider, id, title, mode, max}`: `mode` is `now`, `reset` or `stop`.
- `refresh`: send the state again.
- `diag` `{log}`: new lines of the phone's delivery log, kept by the Mac in `phone-delivery.log`.

## Live Activity

`state.live` is what the Lock Screen shows, or nothing:

```json
{"items":[{"id":"<collapse id>","kind":"attention","provider":"codex","title":"Codex ждёт вашего решения",
  "buttons":[{"id":"choice:allow","title":"Разрешить","primary":true,"auth":true}]}],
 "more":1,"countdowns":[{"provider":"claude","until":1761400000,"waiting":1}],
 "working":[{"provider":"codex","since":1761389000,"count":2}],"updated":1761390000}
```

- `items`: up to two cards with buttons, most urgent first (attention, then reset, then warning).
  Titles are general: never the chat name or the command.
- `more`: how many other cards wait.
- `working`: agents at work and since when; pauses up to 45 seconds between turns count as one
  stretch, and a finished turn ends it at once. Sent only to phones whose app shows it.
- `countdowns`: spent limits that a task is waiting on, and when they come back (a bare spent limit is shown only in the Mac menu bar). When one runs out the Mac sends the state
  again, so the countdown goes away instead of standing at 0:00.

The Mac sends `la` frames: `start` when something new appears and nobody is at the Mac, `update`
otherwise, `end` when nothing is left. The relay starts at most one Live Activity per phone every two
minutes, and a new activity token replaces the old ones.

## What reaches the phone, and how

- At the Mac: nothing interrupts. Cards are in the app; after half a minute at the Mac the Live Activity
  goes, and it comes back (without a sound) when you leave.
- "At the Mac" means real input: a hardware mouse, trackpad or keyboard within two minutes. Input
  made by apps — Codex Computer Use, remote control from a phone, scripts — does not count; the Mac
  tells them apart by the event's source (an event tap that only listens).
- Away (screen locked, display asleep, or no real input for two minutes): cards with buttons go to the Live Activity; the rest
  go as notifications. Requests are time-sensitive, resets are passive, numbers and summaries stay in
  the app.
- A Claude limit comes back while you're away: the "Continue" card goes to the phone right away; the
  Mac shows it when you're back, unless the phone already answered it.
- The Mac is offline for 15 minutes while work waits for a reset: the relay sends one notification.
- The Mac is gone for 5 minutes while a Live Activity shows: the relay marks it out of date, and
  the Lock Screen says the Mac has not been in touch. The Mac refreshes it when it is back.
- The relay itself unreachable for 10 minutes: the Mac shows a card saying the iPhone gets nothing.
- The Mac going to sleep while agents work or tasks wait: the phone is told first.
- The app icon badge counts cards waiting for a press; every push carries the current number.
- The same card again within ten minutes (new words, same news): replaced on the phone quietly.
- A Live Activity with buttons that does not appear within 45 seconds: its cards go as notifications.
- A Live Activity the Mac closed while the phone had not yet reported it (the app not running since
  the phone restarted): the relay wakes the app with a silent push and it closes the activity itself.
- A Live Activity older than seven and a half hours is started afresh, quietly: iOS ends one by
  itself after eight hours without telling the Mac.
- Keeping the line open: on some mobile networks the phone's connection to Apple goes quiet and
  pushes wait up to ten minutes. While something may come (an agent works, a card
  waits for a press, a limit comes back within 15 minutes) the Mac sends a silent push: every two and
  a half minutes while the phone is on mobile data, every ten minutes on Wi‑Fi (only to notice it
  left the Wi‑Fi; the phone names its network with each confirmation). The phone shows nothing. It can be turned off in Settings → iPhone.

## Confirmed delivery

Apple does not say whether a push arrived, so the phone does:

1. The phone's notification extension opens the card and calls `POST /v1/got` with the envelope id.
2. The relay tells the Mac (`delivered`, with how long it took) and stops tracking it.
3. Not confirmed after 45 seconds: the relay sends the same push again, with its sound, and once more
   after 3 minutes. A phone whose link to Apple keeps dropping (seen on mobile data: it reconnects
   about every ten minutes) gets only the newest push Apple holds — a retry — so retries ring too. After 15
   minutes the Mac hears `undelivered`; the push is still kept until its time to live runs out.
4. When a phone confirms one push, others still waiting for it go again at once: Apple keeps only
   the newest push for a phone that was offline.

Pending pushes are kept in `pending-pushes.json` next to the relay's data, so a restart does not
forget them. Only phones whose app confirms are tracked (the relay learns it from their first `POST /v1/got`), so
an older app is never sent the same thing twice. Settings → iPhone → Delivery shows the last result
and has a button that sends a test notification and measures it, plus a rehearsal: a Live Activity
"working" for 40 seconds, then "done" and the Live Activity closes.

Cards also reach the phone when the Mac holds them back (the agent's app is in front), and news
that came while you were at the Mac is pushed when you leave, if it is still open and under ten
minutes old.

## Diagnostics

Every step is logged, without card text:

- Mac, `~/Library/Application Support/Cooldown/activity.log`: each card with its route
  (`push active`, `live activity`, `app only`) and the reason (`no input for 300 s`, `locked`),
  envelope ids, Live Activity starts and ends, presence changes, confirmations and losses.
- Relay (journal): each push with envelope, phone, priority, try and Apple's id; confirmations with
  how long they took; refused envelopes; pushes never confirmed.
- iPhone: the notification extension writes each arrival (delay, inline or fetched, confirmed or
  not), token uploads and Live Activity starts and ends to `delivery.log`. The app shows it under
  Mac → Delivery log and sends new lines to the Mac (`phone-delivery.log`) when opened.

A card's text is cut to 600 characters so it always travels inside the push: the phone shows it
without reaching the relay, which a restricted mobile network might not allow.

## Rules on the Mac

- A command runs once: the Mac remembers command ids for a day.
- A command older than its `ttl` doesn't run. "Continue" lives 30 minutes.
- If the Mac is locked, Claude can't be typed into. The Mac answers `locked`, keeps the command and
  runs it after unlock, if it hasn't expired by then.
- Every command from a phone is written to the feed: "From iPhone: …".

## Trust and limits

- The relay cannot read, forge or redirect a box: each one is sealed for one receiver, with the
  sender, receiver and id bound in. It can only delay or drop them.
- Face ID is asked on the iPhone, before a command leaves it. The Mac trusts a correctly sealed
  command from a paired phone and checks it against its live cards: a button must be one the card
  offers, an answer must be one the agent still waits for, "Ответить" works only on a finished turn.
- A card that cannot show an agent's command whole (too long, long runs of spaces, invisible or
  direction-changing characters) offers no "Allow" — only "Decline" and answering in the app.
- A `cooldown://press` link is accepted only for a button the Live Activity or the latest cards show,
  and Face ID names that button.
- The notification extension remembers the boxes it showed for a day: the same box pushed again
  is not shown twice.
- The relay: 5 phones per Mac, Live Activity frames and receipts limited per device, at most 32
  pushes to Apple at a time; a Mac that never paired a phone is forgotten after a day without
  contact (a week if it was seen again).
