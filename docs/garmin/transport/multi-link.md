# Multi-Link (ML) Transport

The Multi-Link layer sits **above** [GATT](gatt.md) and **below**
[COBS](cobs.md) / GFDI. It multiplexes one BLE characteristic pair into
several logical channels, each identified by a 1-byte handle.

This document describes the live implementation in `Compass:
MultiLinkTransport.swift` (basic ML, the only mode used in production)
and briefly covers the unused MLR encoder in `Compass: MLRTransport.swift`.

---

## Wire format (basic ML)

Every notification from the watch and every write to the watch on the
Garmin V2 send/notify pair starts with a single handle byte:

| Offset | Size | Field    | Notes                                       |
|--------|------|----------|---------------------------------------------|
| 0      | 1    | handle   | `0x00` = management; `0x01..` = service     |
| 1      | N    | payload  | Management body or COBS chunk (see below)   |

Handle `0x00` carries the ML control plane. Handles allocated by the
watch in `REGISTER_ML_RESP` (typically `0x01`) carry COBS-encoded GFDI
fragments.

> Caveat from `Gadgetbridge: CommunicatorV2.java:181-182`: "non-MLR
> handles can also have the msb set, so we let it fall through".
> Compass treats any non-zero handle as a regular service handle and only
> compares against the registered GFDI handle (`Compass:
> MultiLinkTransport.swift:227`).

---

## Management messages (handle `0x00`)

All management messages share a 10-byte header:

| Offset | Size | Field     | Value / notes                         |
|--------|------|-----------|---------------------------------------|
| 0      | 1    | handle    | `0x00`                                |
| 1      | 1    | type      | `RequestType` ordinal (see below)     |
| 2      | 8    | clientId  | LE u64, hardcoded `2`                 |
| 10     | …    | type body | Per-type fields                       |

`Compass: MultiLinkTransport.swift:347-353` builds this header.
`clientID = 2` matches `GADGETBRIDGE_CLIENT_ID` at `Gadgetbridge:
CommunicatorV2.java:53`.

Request types (`Compass: MultiLinkTransport.swift:29-39`,
`Gadgetbridge: CommunicatorV2.java:556-565`):

| Ordinal | Name                |
|---------|---------------------|
| 0       | REGISTER_ML_REQ     |
| 1       | REGISTER_ML_RESP    |
| 2       | CLOSE_HANDLE_REQ    |
| 3       | CLOSE_HANDLE_RESP   |
| 4       | UNK_HANDLE          |
| 5       | CLOSE_ALL_REQ       |
| 6       | CLOSE_ALL_RESP      |
| 7       | UNK_REQ             |
| 8       | UNK_RESP            |

### CLOSE_ALL_REQ — exactly 13 bytes

`Compass: MultiLinkTransport.swift:286-295`:

```
00 05  02 00 00 00 00 00 00 00  00 00
^^ ^^  ^^^^^^^^^^^^^^^^^^^^^^^  ^^^^^
hd type=5         clientId      pad
```

Sent on connect to free any handles a previous (potentially crashed)
session left registered. Without it, repeated reconnects can saturate
the watch's handle pool and force `REGISTER_ML_REQ` to return
`status != 0`.

### REGISTER_ML_REQ — 13 bytes

`Compass: MultiLinkTransport.swift:314-318`:

```
00 00  02 00 00 00 00 00 00 00  01 00  00
^^ ^^  ^^^^^^^^^^^^^^^^^^^^^^^  ^^^^^  ^^
hd t=0         clientId         svc=1  reliable=0
```

Service code `1` = GFDI (`Gadgetbridge: CommunicatorV2.java:580`,
mirrored at `Compass: MultiLinkTransport.swift:26`). Compass always
sets `reliable = 0` (basic ML) — see [Reliable mode](#reliable-mode-mlr)
below.

### REGISTER_ML_RESP — 14 bytes (basic mode)

`Compass: MultiLinkTransport.swift:260-275` parses:

```
00 01  02 00 00 00 00 00 00 00  01 00  00  HH  00
^^ ^^  ^^^^^^^^^^^^^^^^^^^^^^^  ^^^^^  ^^  ^^  ^^
hd t=1         clientId         svc=1  ok hndl rel=0
```

Where `HH` is the assigned GFDI handle (typically `0x01`). The trailing
`reliable` byte is absent on some firmware; the parser treats it as
optional (`Compass: MultiLinkTransport.swift:271`).

### CLOSE_HANDLE_REQ — 13 bytes

`Compass: MultiLinkTransport.swift:172-178` builds it as the head of
`gracefulShutdown()`:

```
00 02  02 00 00 00 00 00 00 00  01 00  HH
^^ ^^  ^^^^^^^^^^^^^^^^^^^^^^^  ^^^^^  ^^
hd t=2         clientId         svc=1  hndl
```

Sent best-effort before disconnecting. Without it, the Instinct Solar's
firmware retains registered services across BLE sessions; eventually
the handle pool saturates and new `REGISTER_ML_REQ` calls return
`status = 2` (failed) — see the rationale at `Compass:
MultiLinkTransport.swift:163-168`.

### Handshake order

1. `decoder.reset()` — clear COBS state from any prior session
   (`Compass: MultiLinkTransport.swift:110`).
2. Start the inbound notification pump (`:111, 205-215`).
3. Send CLOSE_ALL_REQ; await CLOSE_ALL_RESP, 10 s timeout
   (`:113, 286-312`).
4. Send REGISTER_ML_REQ for GFDI; await REGISTER_ML_RESP carrying the
   handle (`:115, 314-344`).
5. Cache `gfdiHandle`. From here every `sendGFDI` prefixes it; every
   inbound notification on this handle is fed to the COBS decoder.

---

## Fragmentation

GFDI messages can exceed the 20-byte `maxWriteSize` cap (see
[gatt.md §MTU](gatt.md#mtu--max-write-size)), so `sendGFDI` chunks the
COBS-encoded buffer:

`Compass: MultiLinkTransport.swift:120-151`:

```
chunkSize = maxWriteSize - 1     // 19 bytes; 1 byte reserved for handle
for each chunk:
    frame = [handle] || cobs[pos..<pos+chunkSize]
    central.write(frame)
```

Only the **first** fragment carries the COBS leading `0x00`; only the
**last** carries the trailing `0x00`. Intermediate fragments are
just `[handle | continuation_bytes]`.

`maxWriteSize` is set by the GFDI client via `setMaxWriteSize(_)`
after parsing `maxPacketSize` from the watch's first
`DEVICE_INFORMATION` (5024) message (`Compass:
MultiLinkTransport.swift:86-96`). Compass clamps the value to 20 bytes
regardless of what the watch reports — see the cap rationale in the
GATT doc.

### Per-message lock

`sendInFlight` plus a `[CheckedContinuation<Void, Never>]` waiter list
(`Compass: MultiLinkTransport.swift:62-63, 127-132, 154-160`)
serialises whole GFDI messages. Without it, an unsolicited-message ACK
fired by the GFDI layer concurrently with a post-pair burst could
interleave fragments of two different GFDI messages, leaving the watch
unable to reassemble either.

---

## Inbound dispatch

The notification pump (`Compass: MultiLinkTransport.swift:205-237`)
reads `central.notifications()` and, for each notification:

1. Reads `handle = raw[0]`, `body = raw[1...]`.
2. If `handle == 0`, dispatches to `handleManagement(body)` for parsing
   `CLOSE_ALL_RESP` / `REGISTER_ML_RESP`.
3. If `handle == gfdiHandle`, feeds `body` to the COBS decoder, then
   yields each completed message on `gfdiContinuation`.
4. Any other handle is logged and dropped.

The COBS decoder is stateful — fragments accumulate until the trailing
`0x00` arrives. See [cobs.md](cobs.md) for the interleave-fix detail.

---

## Reliable mode (MLR)

Compass currently uses **basic ML only** — `reliable = 0` is hardcoded
at `Compass: MultiLinkTransport.swift:317`. The `MLRTransport.swift`
file is **future infrastructure** that implements the bit-packed MLR
header but is not wired into the connect path.

### Why basic ML

* Gadgetbridge only opts into MLR when the user enables the
  experimental preference `garmin_mlr` AND the watch advertises
  `MULTI_LINK_SERVICE` capability (`Gadgetbridge: GarminSupport.java:538-540`,
  `GarminCapability.java:107`).
* Instinct Solar 1G does not advertise that capability. Setting
  `reliable = 2` would either be rejected outright or accepted with the
  watch silently never sending data afterwards.

### MLR wire format (for future wiring)

`Compass: MLRTransport.swift:78-105` encodes a 2-byte header:

| Bits      | Field            |
|-----------|------------------|
| `byte0[7]`    | always `1` (MLR marker) |
| `byte0[6:4]`  | handle (3 bits, 0–7)    |
| `byte0[3:0]`  | reqNum high 4 bits      |
| `byte1[7:6]`  | reqNum low 2 bits       |
| `byte1[5:0]`  | seqNum (6 bits, 0–63)   |

`reqNum` is a cumulative ACK of frames received from the peer;
`seqNum` increments per outbound frame on a given handle. The
`HandleState` struct (`:43-52`) tracks `sendSeqNum`, `recvSeqNum`,
`lastAckSent` per handle. Decode logic at `:129-161` mirrors encode.

`Compass: HandleManager.swift` provides 4-bit handle assignment for
that future MLR path; it is not used by the live `MultiLinkTransport`.

Reference: `Gadgetbridge: MlrCommunicator.java:239-252` (encode);
`Gadgetbridge: MlrCommunicator.java:19-30` (constants — `ACK_TIMEOUT =
250 ms`, `INITIAL_RETRANSMISSION_TIMEOUT = 1000 ms`,
`ACK_TRIGGER_THRESHOLD = 5`).

---

## Source

* `Compass: Packages/CompassBLE/Sources/CompassBLE/Transport/MultiLinkTransport.swift` (live)
* `Compass: Packages/CompassBLE/Sources/CompassBLE/Transport/MLRTransport.swift` (future)
* `Compass: Packages/CompassBLE/Sources/CompassBLE/Transport/HandleManager.swift` (future)
* `Compass: Packages/CompassBLE/Sources/CompassBLE/Transport/FrameAssembler.swift` (future, GFDI length-prefix reassembly)
* `Gadgetbridge: service/devices/garmin/communicator/v2/CommunicatorV2.java:50-665`
* `Gadgetbridge: service/devices/garmin/communicator/v2/MlrCommunicator.java:19-310`
* `docs/garmin/references/gadgetbridge-pairing.md` §3, §9, §10

Cross-references: [gatt.md](gatt.md), [cobs.md](cobs.md),
[crc16.md](crc16.md).
