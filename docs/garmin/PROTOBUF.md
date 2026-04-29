# GFDI Protobuf Channel

GFDI message types **5043** (`protobufRequest`, 0x13B3) and **5044** (`protobufResponse`,
0x13B4) carry Protocol Buffer payloads for structured data exchange between phone and watch.

> **Note on types 5004/5005**: These are `fileTransferData` and `createFile` — file-sync
> messages, not protobuf. The protobuf channel is exclusively 5043/5044.

---

## Compass approach: hand-rolled ProtoEncoder

Compass does **not** use the SwiftProtobuf library or generated `.pb.swift` files.
Instead, a minimal hand-rolled encoder (`Utils/ProtoEncoder.swift`) writes proto wire
format directly for the specific messages needed.

### Supported wire types

| Wire type | Proto type(s) | ProtoEncoder method |
|---|---|---|
| 0 (varint) | uint32, enum | `writeUInt32(field:value:)` |
| 0 (varint) | sint32 (zigzag) | `writeSInt32(field:value:)` |
| 0 (varint) | enum | `writeEnum(field:value:)` |
| 2 (len-delim) | embedded message | `writeMessage(field:body:)` |
| 2 (len-delim) | bytes | `writeBytes(field:value:)` |
| 5 (32-bit) | float | `writeFloat(field:value:)` |

Usage pattern — build a nested message bottom-up:

```swift
var inner = ProtoEncoder()
inner.writeSInt32(field: 1, value: latitudeE7)
inner.writeSInt32(field: 2, value: longitudeE7)

var outer = ProtoEncoder()
outer.writeMessage(field: 3, body: inner.data)

let payload = outer.data
```

---

## Incoming protobufRequest (5043) — current handling

The watch sends `protobufRequest` messages (e.g. for Smart/GdiSmartProto settings
negotiation, battery status, etc.). Compass ACKs them with a `RESPONSE (5000)`:

```
RESPONSE payload for protobufRequest:
  [originalType: 0xB3 0x13]   // 5043 LE
  [status: 0x00]               // ACK
  [requestId: UInt16 LE]       // echoed from incoming payload[0..1]
  [dataOffset: UInt32 LE = 0]
  [chunkStatus: UInt8 = 0]     // KEPT
  [statusCode: UInt8 = 0]      // NO_ERROR
```

No full proto decode is performed. The watch retransmits unanswered proto requests every ~1 s,
so the ACK-only approach is sufficient to suppress retransmissions.

**Source**: `GarminDeviceManager.swift:handleUnsolicited` (`.protobufRequest` case)

---

## Outgoing: PhoneLocation

`PhoneLocation.swift` pushes GPS coordinates to the watch using `protobufResponse` (5044),
encoding a `Smart.CoreService.LocationUpdatedNotification` with the hand-rolled encoder.

**Source**: `PhoneLocation.swift`, `ProtoEncoder.swift`

---

## Proto definitions (reference only)

The proto message definitions come from the Gadgetbridge repository:

```
https://codeberg.org/Freeyourgadget/Gadgetbridge
app/src/main/proto/
```

Key files for reference:

| File | Purpose |
|---|---|
| `garmin_vivomovehr.proto` | Top-level message wrappers |
| `smart_proto_core.proto` | Smart/CoreService (location, etc.) |
| `device_status.proto` | Battery reporting |
| `music_control.proto` | Music playback control |
| `weather.proto` | Weather data |

These are reference material only — they are not compiled into Compass.
