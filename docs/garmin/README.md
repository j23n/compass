# Garmin BLE Protocol — Compass Documentation

This directory documents the Garmin BLE protocol stack as implemented by
**Compass** (the iOS app in this repo). Compass syncs FIT files, course
uploads, weather, notifications, and music control with Garmin watches over
Bluetooth Low Energy. Everything here is derived from working Swift code in
`Packages/CompassBLE` and `Packages/CompassFIT`, validated live against a
Garmin Instinct Solar (1st gen) running firmware 19.1.

When the source code disagrees with the docs, the source code wins. When the
docs disagree with Gadgetbridge, [`references/`](references/) wins.

---

## The protocol stack

Garmin's BLE protocol is a layer cake. Each layer wraps the one below it:

```
┌───────────────────────────────────────────────────────────────┐
│  FIT  — application data: activities, sleep, monitoring, …    │   fit/
│  payload of file-transfer messages, also weather definitions  │
├───────────────────────────────────────────────────────────────┤
│  GFDI — request/response envelope (length, type, payload, CRC)│   gfdi/
│  carries: file-sync, system events, protobuf, music, weather  │
├───────────────────────────────────────────────────────────────┤
│  COBS — framing (zero-byte delimited, no escaping)            │   transport/cobs.md
├───────────────────────────────────────────────────────────────┤
│  ML   — Multi-Link control plane (CLOSE_ALL, REGISTER_ML, …)  │   transport/multi-link.md
├───────────────────────────────────────────────────────────────┤
│  GATT — BLE service `6A4E2800-…` + write/notify chars         │   transport/gatt.md
└───────────────────────────────────────────────────────────────┘
```

A typical message lifetime: a Compass `DownloadRequestMessage` (GFDI type 5002)
is serialized into a GFDI frame (length + type + payload + CRC-16), wrapped in
COBS, prefixed with the ML channel byte, chunked across one or more BLE write
operations on characteristic `6A4E2820-…`. The watch's reply travels back the
other direction on `6A4E2810-…`.

The CRC used at the GFDI layer is Garmin's nibble-table CRC-16 — the same
polynomial used by FIT files. See [`transport/crc16.md`](transport/crc16.md).

---

## Where Compass implements each layer

| Layer | Compass module | Key file(s) |
|-------|----------------|-------------|
| GATT  | `CompassBLE` | `BluetoothCentral.swift` |
| ML    | `CompassBLE` | `Transport/MultiLinkTransport.swift` |
| COBS  | `CompassBLE` | `Transport/CobsCodec.swift` |
| CRC-16| `CompassBLE` | `Utils/CRC16.swift` |
| GFDI  | `CompassBLE` | `GFDI/MessageTypes.swift`, `GFDI/Messages/*.swift`, `GFDI/GFDIClient.swift` |
| File sync | `CompassBLE` | `Sync/FileSyncSession.swift`, `Sync/FileUploadSession.swift` |
| FIT decode | `CompassFIT` | `Parsers/FITDecoder.swift`, `Parsers/*.swift` |
| FIT encode | `CompassFIT` | `Encoders/CourseFITEncoder.swift` |

The two packages are decoupled: `CompassFIT` knows nothing about BLE and can
parse FIT files from any byte source (USB dump, on-disk export, BLE stream).
`CompassBLE` produces and consumes raw FIT bytes; the GFDI layer wraps and
unwraps them.

---

## Documentation map

### Transport — [`transport/`](transport/)

| Doc | Topic |
|-----|-------|
| [`gatt.md`](transport/gatt.md) | GATT service, write/notify characteristics, scanning |
| [`multi-link.md`](transport/multi-link.md) | V2 Multi-Link control plane |
| [`cobs.md`](transport/cobs.md) | COBS framing and the partial-frame interleave fix |
| [`crc16.md`](transport/crc16.md) | Garmin nibble-table CRC-16 |

### GFDI — [`gfdi/`](gfdi/)

| Doc | Topic |
|-----|-------|
| [`message-format.md`](gfdi/message-format.md) | Length + type + payload + CRC envelope; RESPONSE wrapping |
| [`message-types.md`](gfdi/message-types.md) | Full GFDI message-type catalog (5000-series) |
| [`pairing.md`](gfdi/pairing.md) | Initial handshake, authentication, post-init bursts |
| [`system-events.md`](gfdi/system-events.md) | `SystemEvent` codes (pair/sync start/complete) |
| [`file-sync-download.md`](gfdi/file-sync-download.md) | Watch → phone file transfer (5002/5004/5008) |
| [`file-sync-upload.md`](gfdi/file-sync-upload.md) | Phone → watch upload (course files) |
| [`weather.md`](gfdi/weather.md) | Weather request → FIT_DEFINITION + FIT_DATA reply |
| [`protobuf.md`](gfdi/protobuf.md) | PROTOBUF_REQUEST / PROTOBUF_RESPONSE, status block |
| [`music.md`](gfdi/music.md) | Music control + capabilities |
| [`find-my-phone.md`](gfdi/find-my-phone.md) | Ring / cancel handlers |

### FIT — [`fit/`](fit/)

| Doc | Topic |
|-----|-------|
| [`format.md`](fit/format.md) | FIT wire format: file header, definition/data records, base types, CRC |
| [`compressed-timestamps.md`](fit/compressed-timestamps.md) | The 1-byte compressed-timestamp header |
| [`messages.md`](fit/messages.md) | Catalog: msgs 18, 20, 55, 273–276, 306–318, etc. |

### Devices — [`devices/`](devices/)

| Doc | Topic |
|-----|-------|
| [`instinct-solar-1g.md`](devices/instinct-solar-1g.md) | Instinct Solar (1st gen): features, FIT files, firmware quirks |

### References — [`references/`](references/)

| Doc | Topic |
|-----|-------|
| [`gadgetbridge-pairing.md`](references/gadgetbridge-pairing.md) | Byte-level walkthrough of GB's pairing code (V2 ML + COBS + GFDI) |
| [`gadgetbridge-sync.md`](references/gadgetbridge-sync.md) | Byte-level walkthrough of GB's file-sync code |

These are the **authoritative** Java-source walkthroughs; consult them
whenever a Compass behavior is ambiguous against the watch's actual response.

---

## Where to start

| If you are… | Read first |
|-------------|-----------|
| Debugging pairing / authentication | [`gfdi/pairing.md`](gfdi/pairing.md) → [`references/gadgetbridge-pairing.md`](references/gadgetbridge-pairing.md) |
| Adding a new FIT message parser | [`fit/messages.md`](fit/messages.md) → [`fit/format.md`](fit/format.md) |
| Investigating a sync that hangs or drops files | [`gfdi/file-sync-download.md`](gfdi/file-sync-download.md) → [`devices/instinct-solar-1g.md`](devices/instinct-solar-1g.md) §5 |
| Sending a course / route to the watch | [`gfdi/file-sync-upload.md`](gfdi/file-sync-upload.md) |
| Adding a protobuf push (notifications, location) | [`gfdi/protobuf.md`](gfdi/protobuf.md) |
| Implementing a new transport feature | [`transport/multi-link.md`](transport/multi-link.md) → [`transport/cobs.md`](transport/cobs.md) |
| Investigating what a specific watch produces | [`devices/`](devices/) |

---

## Quick reference

### BLE service base UUID

```
6A4E____-667B-11E3-949A-0800200C9A66
```

| Suffix | Role |
|--------|------|
| `2800` | V2 ML GFDI service |
| `2810` | Notify (watch → phone) |
| `2820` | Write  (phone → watch) |
| `2801` / `2802` | V1 fallback |

Full table in [`transport/gatt.md`](transport/gatt.md).

### Key GFDI message types

| Hex    | Dec  | Symbol                   | Purpose |
|--------|-----:|--------------------------|---------|
| 0x1388 | 5000 | `RESPONSE`               | Generic ACK/NACK envelope |
| 0x138A | 5002 | `DOWNLOAD_REQUEST`       | Phone → watch: pull a FIT file |
| 0x138B | 5003 | `UPLOAD_REQUEST`         | Phone → watch: push a file |
| 0x138C | 5004 | `FILE_TRANSFER_DATA`     | Chunk body (download or upload) |
| 0x1390 | 5008 | `SET_FILE_FLAG`          | Mark file archived/deleted |
| 0x13A0 | 5024 | `DEVICE_INFORMATION`     | Watch announces itself (first frame post-ML) |
| 0x13A6 | 5030 | `SYSTEM_EVENT`           | Lifecycle: pair/sync start/complete |
| 0x13B3 | 5043 | `PROTOBUF_REQUEST`       | Wraps a protobuf payload (in) |
| 0x13B4 | 5044 | `PROTOBUF_RESPONSE`      | Wraps a protobuf payload (out/in) |
| 0x13ED | 5101 | `AUTH_NEGOTIATION`       | Pairing auth handshake (watch-initiated, optional) |

Full table in [`gfdi/message-types.md`](gfdi/message-types.md).

### Garmin epoch

All Garmin timestamps are **seconds since 1989-12-31 00:00:00 UTC**:

```
unix_seconds = garmin_seconds + 631_065_600
```

Helpers: `FileEntry.dateFromGarminEpoch(_:)`, `FITTimestamp.date(from:)`.

---

_Compass implementation: `Packages/CompassBLE/`, `Packages/CompassFIT/`._
_Reference source: Gadgetbridge (`org.gadgetbridge.service.devices.garmin`)._
