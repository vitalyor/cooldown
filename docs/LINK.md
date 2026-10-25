# Cooldown Link

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
- Live Activity content: limit percentages, reset times and counters. iOS gives a Live Activity no
  way to decrypt anything on the device, so this part travels in plain form. It never carries chat
  titles, answers or file paths.

Everything else (cards, their texts and buttons, chat lists, commands, results) is sealed on one
device and opened on the other.

## Keys

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
- A message for a device that is offline waits until `ttl` runs out (at most a day, 200 per device).

## Messages inside a box

```json
{"m":"state","id":"…","ts":1761369000, ...}
```

| `m` | From | Fields |
|---|---|---|
| `state` | Mac | `limits`, `agents`, `watches`, `mac` |
| `card` | Mac | `card {key, kind, provider, title, body, actions [{id, title, style}], created, expires}` |
| `resolve` | both | `key`, `by`: a card was answered or closed somewhere |
| `cmd` | phone | `id`, `op`, `args` |
| `result` | Mac | `cmd`, `ok`, `text`, `data` |

Commands (`op`):

- `card.act` `{key, action}`: press a card button. The Mac checks the card is still open first and
  answers `stale` if it isn't.
- `chats` `{provider}`: list Codex conversations or Claude chats.
- `watch` `{provider, id, title, mode, max}`: `mode` is `now`, `reset` or `stop`.
- `refresh`: send the state again.

## Rules on the Mac

- A command runs once: the Mac remembers command ids for a day.
- A command older than its `ttl` doesn't run. "Continue" lives 30 minutes.
- If the Mac is locked, Claude can't be typed into. The Mac answers `locked`, keeps the command and
  runs it after unlock, unless the phone cancels it.
- Every command from a phone is written to the feed: "From iPhone: …".
