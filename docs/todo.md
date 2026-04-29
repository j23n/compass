# Pairing TODO

What's still missing for full Garmin pairing on the Instinct Solar 1
(and likely every other Garmin V2 watch). This is the punch list to take
the connection from "GFDI handshake completes" → "watch exits the
post-pair setup wizard and is fully operational".

The on-wire layers that matter are documented in
[`gadgetbridge-instinct-pairing.md`](gadgetbridge-instinct-pairing.md). What follows
references that doc throughout.

---

## Where we are

| Layer | Status |
|---|---|
| GATT scan / connect / characteristic discovery | ✅ |
| V2 Multi-Link control plane (CLOSE_ALL_REQ + REGISTER_ML_REQ → handle) | ✅ |
| COBS encode / decode (incl. multi-message buffer split) | ✅ |
| GFDI message framing + Garmin CRC-16 | ✅ |
| Per-message send lock (atomic multi-fragment writes) | ✅ |
| Per-write FIFO queue in `BluetoothCentral` | ✅ |
| Bare 9-byte ACKs for unsolicited messages | ✅ |
| `CURRENT_TIME_REQUEST` (0x13BC) — proper response with Garmin epoch ts | ✅ |
| GFDI handshake: DEVICE_INFORMATION → CONFIGURATION → SUPPORTED_FILE_TYPES_REQUEST → DEVICE_SETTINGS → SYNC_READY → PAIR_COMPLETE / SYNC_COMPLETE / SETUP_WIZARD_COMPLETE | ✅ |
| `gracefulShutdown()` — `CLOSE_HANDLE_REQ` for GFDI before BLE drop | ✅ |
| `releaseSendLock()` deadlock fix — clears `sendInFlight` before waking waiters | ✅ |
| `PROTOBUF_REQUEST` (0x13B3) — proper ProtobufStatusMessage ACK (not bare 9-byte ACK) | ✅ |
| `MUSIC_CONTROL_CAPABILITIES` (0x13B2) — reply with zero capabilities to stop 1-Hz retransmit | ✅ |
| Watch exits post-pair setup wizard | ⏳ needs real-watch test |
| File sync (FIT pull) | ❌ |
| File upload (course push) | ❌ |
| Notifications, music control, weather, find-my-phone, etc. | ❌ |

---

## Why the watch stays in setup-wizard UI

### Observed behaviour

- **The Compass app stays on the pairing-spinner UI indefinitely.** It
  does **not** report "Pairing succeeded" — `GarminDeviceManager.pair()`
  never returns, so the SyncCoordinator never transitions to `.paired`.
  The handshake bytes complete on the wire (we see the SYSTEM_EVENTs
  go out and the watch ACK them in the logs), but the Swift
  control-flow never reaches the success path.
- The **watch's** pair-UI screen also stays on the "go to phone to
  continue" prompt. If the user manually swipes/clicks out of that
  screen on the watch, the watch shows a "continue setup?" prompt
  rather than going to its normal home screen — so the watch
  believes it is **mid-setup**, not unpaired and not fully set up.
  The handshake clearly progressed enough that the watch knows "a
  host is connected" — it just isn't satisfied setup has finished.
- This matches the protocol picture below: the watch is waiting on
  post-pair onboarding RPCs that we don't yet answer with real data.
  The `SETUP_WIZARD_*` SystemEvent we send is informational; the
  watch's actual setup state machine is gated on the protobuf
  conversation.

### ~~App-side cause: `sendInFlight` deadlock~~ — **FIXED**

`MultiLinkTransport.releaseSendLock()` was only clearing `sendInFlight = false`
when there was **no** waiter. When a waiter existed it woke them but left
`sendInFlight = true`, causing the woken task to immediately re-suspend →
permanent deadlock.

**Fix applied** (`MultiLinkTransport.swift`): `releaseSendLock()` now sets
`sendInFlight = false` unconditionally before waking the next waiter. Actor
serialization guarantees the woken task gets the exclusive slot.

### Why

After our handshake completes, the watch enters a request loop and
re-sends the same set of messages every 1-8 seconds because we don't
answer with real data:

| Type | Hex | Cadence | What the watch wants |
|---|---|---|---|
| `MUSIC_CONTROL_CAPABILITIES` | `0x13B2` | every ~1 s | the host's music control feature set |
| `WEATHER_REQUEST` | `0x1396` | every ~5 s | current weather conditions |
| `PROTOBUF_REQUEST` | `0x13B3` | bursts every ~7-8 s | RPC questions encoded as `Smart.GdiSmartProto`: settings init, locale, contacts permission, find-my-phone capability, etc. |

Today we reply to every one of these with a **bare 9-byte
`RESPONSE/ACK`** (`type=5000`, `originalType=…`, `status=ACK`, no
payload). That's enough to stop *some* retransmits but not the watch's
post-pair onboarding state machine — it needs at least one
`PROTOBUF_RESPONSE (0x13B4)` carrying a real protobuf payload before it
will dismiss the wizard.

A bare `ACK` is the protocol equivalent of "I got your request, I'm
working on it." A real `PROTOBUF_RESPONSE` is the actual answer.

Quick workaround already attempted: replace `SETUP_WIZARD_COMPLETE` (14)
with `SETUP_WIZARD_SKIPPED` (15) in the post-pair burst. Need to verify
on a fresh watch run whether the watch interprets that as "this host
doesn't run a setup wizard, dismiss it." If yes, we're good for now.

---

## The smallest viable thing to make pair-UI exit — **IMPLEMENTED**

Investigation of Gadgetbridge's `ProtocolBufferHandler.java` and
`ProtobufMessage.java` revealed the actual protocol (different from initial
assumption):

### 1. ~~Protobuf encoder/decoder~~ — **not needed**

Gadgetbridge does **not** send a `PROTOBUF_RESPONSE (0x13B4)` in reply to
the watch's `initRequest`. It sends a specialized `RESPONSE (0x1388)` with
extended ProtobufStatusMessage fields. No protobuf encoding is required.

### 2. ~~`SettingsService.InitRequest` → `InitResponse`~~ — **not needed**

The initial assumption was wrong. Gadgetbridge only sends a ProtobufStatusMessage
ACK to `initRequest` (no `InitResponse` body). The watch accepts this.

**What was actually needed:** send the extended ACK format instead of the bare
9-byte ACK. The `PROTOBUF_REQUEST` GFDI payload starts with a 2-byte `requestId`
that must be echoed back. Wire shape of the correct ACK:

```
RESPONSE (0x1388) payload:
  [2: 0x13B3 originalType LE]
  [1: 0x00 status=ACK]
  [2: requestId LE]      ← echoed from incoming PROTOBUF_REQUEST
  [4: 0x00000000 dataOffset]
  [1: 0x00 chunkStatus=KEPT]
  [1: 0x00 statusCode=NO_ERROR]
```

**Implemented** in `GarminDeviceManager.handleUnsolicited`, case `.protobufRequest`.

Proto field numbers (verified from `garmin/gdi_smart_proto.proto` and
`garmin/gdi_settings_service.proto` in Gadgetbridge):

| Message | Field | Number |
|---|---|---|
| `Smart` | `settings_service` | **42** |
| `SettingsService` | `initRequest` | 8 |
| `SettingsService` | `initResponse` | 9 |
| `InitResponse` | `unk1` (locale?) | 1 |
| `InitResponse` | `unk2` (region?) | 2 |

These are documented for reference; full protobuf encode/decode is only needed
if the watch ever requires an actual `InitResponse` body (not currently required).

### 3. Reply to `MUSIC_CONTROL_CAPABILITIES` with zero capabilities — **IMPLEMENTED**

`RESPONSE (0x1388)` with payload `[0xB2, 0x13, 0x00, 0x00]`:
  - originalType = 0x13B2
  - status = ACK
  - commandCount = 0 (no music commands supported)

Matches Gadgetbridge `MusicControlCapabilitiesMessage.generateOutgoing`. Watch
stops re-asking once it receives this.

### 4. (Optional) Reply to `WEATHER_REQUEST` with "no weather"

Bare ACK already stops retransmits. Full weather payload deferred.

---

## App-side: live connection indicator

The UI currently has no way to show whether the watch is **actually
connected right now** vs. merely "paired in the past". Symptoms:

- `SyncCoordinator.pairingState` has a `.paired` state that's set once
  inside `pair()` after `runHandshake()` returns, then never updated.
  Once `pair()` returns the coordinator forgets about the live link.
- `ConnectedDevice` in SwiftData is a record of "this device is paired
  with Compass". It's read by `TodayView` and `SettingsView` via
  `@Query`. From SwiftData's view a device is "connected" forever as
  long as the row exists.
- `GarminDeviceManager.isConnected` exists on the actor but nothing
  in the UI subscribes to it, and it doesn't fire on BLE link drops
  unless we explicitly call `disconnect()`. CoreBluetooth's
  `centralManager(_:didDisconnectPeripheral:error:)` updates
  `BluetoothCentral` internal state but doesn't propagate to
  `GarminDeviceManager._isConnected` or the UI.

What's needed:

1. **A `@Published` (or `AsyncStream`-backed) connection-state
   property** on something the UI can subscribe to. Probably on
   `SyncCoordinator` since that's already a `@Bindable` /
   `@Observable` source for the views.
2. **Wire CoreBluetooth disconnect events through the stack** so when
   the watch goes out of range / powers off / drops, the app's
   "connected" indicator flips to "disconnected" without the user
   having to do anything.
   - `BluetoothCentral.didDisconnect(error:)` already runs on the
     actor — just needs to publish to a state stream.
   - `MultiLinkTransport` and `GFDIClient` should propagate this
     upward (e.g. via an `AsyncStream<ConnectionState>` exposed on
     `GarminDeviceManager`).
   - `SyncCoordinator` subscribes to that stream and updates a
     published `connectionState: ConnectionState` enum (likely
     `.disconnected`, `.connecting`, `.connected`, `.failed(Error)`).
3. **Auto-reconnect when the link drops** (later — for now showing
   the disconnect state honestly is the priority).
4. **Show the indicator in the UI**:
   - Settings view: device row should have a connection badge
     (green dot / "Connected", gray / "Disconnected").
   - Today view: header pill ("Connected to Instinct Solar" /
     "Watch not connected") so the user knows whether a sync is
     possible right now.
5. Today's `pairingState` enum probably wants to be split into "pair
   flow state" (the `.idle / .scanning / .pairing / .paired / .failed`
   spinner-driving thing) and "live connection state" (steady-state
   indicator for an already-paired device). They serve different UIs
   and conflating them is what got us into the "spinner won't go
   away" failure mode.

Where the live state should come from:

- `peripheral.state` (`.connected`/`.disconnected`/etc.) — primary truth
- `BluetoothCentral.didDisconnect(error:)` — async edge trigger to flip
  the UI immediately rather than poll
- `GarminDeviceManager.isConnected` — currently a snapshot bool;
  should become an `AsyncStream<Bool>` or `@Observable` actor property

## Other gaps after pair-UI exits

These don't block pairing but are needed for the app's actual purpose
(reading FIT activity files):

### File sync (FIT pull)

The whole `Sync/` package was deleted along with the protobuf layer.
What's needed:

- `DirectoryFileFilterRequest` / `FILTER` (`0x138F`) — ask the watch for
  a directory listing of activity files
- Handle `FILE_TRANSFER_DATA` (`0x138C`) — chunked file streaming
- `DOWNLOAD_REQUEST` (`0x138A`) — request a file by filename / data ID
- `SET_FILE_FLAG` (`0x1390`) — mark files as transferred so the watch
  doesn't re-offer them

Reference: Gadgetbridge `FileTransferHandler` + the `gadgetbridge-instinct-sync.md` doc.

### File upload (course push)

Inverse of the pull flow:
- `CREATE_FILE` (`0x138D`) — declare we're going to upload a file
- `UPLOAD_REQUEST` (`0x138B`) — start the upload
- `FILE_TRANSFER_DATA` chunks back to the watch

### Time sync is broken

Two separate problems:

1. **`TIME_UPDATED` SystemEvent** is currently skipped from the
   post-pair burst (see `runHandshake()` comment). We were sending
   `eventValue=0` as a single `UInt8` byte — the watch needs a 4-byte
   Garmin-epoch timestamp. Per Gadgetbridge `SystemEventMessage`, the
   `value` field is variable-width: 1 byte for ordinal-style events
   (`PAIR_COMPLETE` etc.), 4 bytes for time, length-prefixed string
   for others. Our `SystemEventMessage.eventValue: UInt8` model needs
   to become an enum-of-shapes (or bytes) before this can work.

2. **`CURRENT_TIME_REQUEST` (0x13BC) response is wrong on the wire.**
   The watch keeps re-asking. The handler in
   `GarminDeviceManager.respondToCurrentTimeRequest` sends:
   ```
   [originalType=0x13BC][status=ACK]
   [refID:UInt32 LE][garminTs:UInt32 LE][tzOffset:Int32 LE][0:4][0:4]
   ```
   This matches Gadgetbridge's `CurrentTimeRequestMessage.generateOutgoing`
   on paper, but in practice the watch's clock isn't being set. Things
   to investigate:
   - Garmin epoch offset constant (currently `631_065_600`). Spot
     check: `Date(timeIntervalSince1970: 631065600)` should be
     1989-12-31 00:00:00 UTC.
   - `tzOffset` — sign convention (Gadgetbridge uses signed seconds
     east of GMT; we follow that, but worth double-checking the
     watch's interpretation).
   - DST transition fields — currently both zero. Some firmware may
     reject the response if these aren't sensible.
   - Whether the response needs to also be wrapped in additional
     fields the doc didn't capture. Cross-check the actual on-the-wire
     bytes vs. a Gadgetbridge capture.
   - Whether the watch even uses our response or only the
     `TIME_UPDATED` SystemEvent (item 1 above) for its clock.

### Reconnect / bond persistence

Today every pair attempt does the full handshake from scratch. Once the
watch is bonded with iOS, `connect()` should:

- Skip the SMP-pairing step (already handled by iOS automatically — the
  bond persists)
- Skip `SETUP_WIZARD_*` events (only fire on `mFirstConnect`)
- Send `SYNC_READY` and start syncing immediately

The mFirstConnect-vs-reconnect distinction in Gadgetbridge is
`GarminSupport.mFirstConnect` — see §13 of the doc. We currently send
the `mFirstConnect` events on every pair attempt.

### File-sync handles (FILE_TRANSFER_2 / 4 / 6 / A / C / E)

Gadgetbridge registers separate ML services for each parallel file
transfer — service codes `0x2018`, `0x4018`, `0x6018`, `0xA018`,
`0xC018`, `0xE018` (see `CommunicatorV2.Service` enum). Allows up to 6
concurrent FIT downloads. Our `MultiLinkTransport` only registers GFDI
(service code 1).

Not required to start syncing — the GFDI handle can carry file transfer
data sequentially. But for performance / parallelism eventually.

### Realtime services

`REALTIME_HR (6)`, `REALTIME_STEPS (7)`, `REALTIME_HRV (12)`, etc. —
each is its own ML service. Out of scope for "pair + read FIT files"
but exists for future expansion.

---

## Test gaps

- `CobsCodec` unit tests for the multi-message buffer case (the bug we
  just fixed where `lastIndex(of: 0)` produced corrupt frames). Should
  test: two complete frames in one `receivedBytes` call → both decode
  correctly via two `retrieveMessage()` calls.
- `BluetoothCentral` write-queue tests (concurrent writers don't lose
  continuations) — currently nothing in the test suite exercises the
  concurrent-writer race that bit us.
- `MultiLinkTransport.sendInFlight` lock test — verify two
  `sendGFDI(...)` calls for multi-fragment messages don't interleave
  on the wire.

---

## Documentation

- The `gadgetbridge-instinct-pairing.md` doc covers handshake
  byte-for-byte but **stops** after `completeInitialization()`. Need a
  follow-up doc that covers the post-pair operational protocol — the
  protobuf RPCs, file transfer, realtime services. Gadgetbridge has all
  of it; just hasn't been ported yet.
- `gadgetbridge-instinct-sync.md` exists in `docs/` already (committed
  in the initial doc commit). Worth re-reading and cross-checking
  against current code.

---

## Quick wins (in order)

1. ✅ **Fix `sendInFlight` deadlock** — `releaseSendLock()` now clears the
   flag unconditionally before waking waiters.
2. ✅ **Send proper `PROTOBUF_REQUEST` status ACK** — echo requestId + extended
   status fields instead of bare 9-byte ACK.
3. ✅ **Send empty `MusicControlCapabilities` reply** — zero-command list stops
   the 1-Hz `0x13B2` retransmits.
4. ⏳ **Verify `SETUP_WIZARD_SKIPPED` workaround on real watch** — code sends
   eventType=15 (SKIPPED); needs a live test. If wizard still stays, try
   SETUP_WIZARD_COMPLETE (14) per Gadgetbridge's default.
5. **Stub `WEATHER_REQUEST` reply** — bare ACK already suppresses retransmits;
   full weather payload deferred.
6. Then file sync.
