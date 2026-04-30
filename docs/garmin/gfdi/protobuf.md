# Protobuf (PROTOBUF_REQUEST / PROTOBUF_RESPONSE)

Compass uses two GFDI message types to tunnel Google Protocol Buffers messages
between the watch and the phone:

| Type   | GFDI ID | Hex      | Direction        |
|--------|---------|----------|------------------|
| 5043   | 5043    | 0x13B3   | watch → phone    |
| 5044   | 5044    | 0x13B4   | phone → watch    |

Compass currently sends `PROTOBUF_RESPONSE` (5044) for exactly one purpose:
pushing phone GPS fixes during live-tracking activities. Incoming
`PROTOBUF_REQUEST` (5043) traffic is acknowledged but never decoded — Compass
does not implement Garmin's full protobuf service catalog.

See also: [`./message-format.md`](./message-format.md), [`./message-types.md`](./message-types.md).

## When 5043 vs. 5044 is used

| Direction      | What it carries (in Compass)                                |
|----------------|-------------------------------------------------------------|
| 5043 incoming  | Service-discovery and capability probes. Compass ACKs only. |
| 5044 outgoing  | `PhoneLocation` push (lat/lon/altitude/bearing/speed).      |

Most Gadgetbridge protobuf services (calendar, contacts, maps tiles, agent
chat, etc.) are not implemented here. The only practical effect of skipping
them is that those features stay disabled on the watch.

## ACKing inbound 5043

Garmin replies to `PROTOBUF_REQUEST` not with a full `PROTOBUF_RESPONSE`
message but with a normal `RESPONSE` (5000) carrying extra bytes that mirror
Gadgetbridge's `ProtobufStatusMessage`:

```
[originalType: UInt16 LE = 0x13B3]
[status:       UInt8     = 0x00 (ACK)]
[requestId:    UInt16 LE]   ← copied from first 2 payload bytes
[dataOffset:   UInt32 LE = 0]
[chunkStatus:  UInt8     = 0 (KEPT)]
[statusCode:   UInt8     = 0 (NO_ERROR)]
```

Compass: `GarminDeviceManager.swift:222-239`:

```swift
case .protobufRequest:
    let requestId: UInt16 = msg.payload.count >= 2
        ? UInt16(msg.payload[0]) | (UInt16(msg.payload[1]) << 8)
        : 0
    var extra = Data()
    extra.appendUInt16LE(requestId)
    extra.appendUInt32LE(0)  // dataOffset = 0
    extra.append(0)          // chunkStatus = KEPT
    extra.append(0)          // statusCode = NO_ERROR
    let pbAck = GFDIResponse(originalType: .protobufRequest,
                             status: .ack,
                             additionalPayload: extra)
    try? await client.send(message: pbAck.toMessage())
```

A bare ACK without those trailing bytes leaves the watch retransmitting every
~1 s — the watch's parser expects the full status frame.

## Wire types supported by `ProtoEncoder`

Compass ships a tiny hand-rolled encoder rather than pulling in
`SwiftProtobuf`. The supported wire types are exactly those needed for the
location stack (`ProtoEncoder.swift:9-67`):

| Wire type | Meaning            | Encoder method                                    |
|-----------|--------------------|---------------------------------------------------|
| 0         | varint             | `writeUInt32`, `writeSInt32` (zigzag), `writeEnum`|
| 2         | length-delimited   | `writeMessage`, `writeBytes`                      |
| 5         | 32-bit fixed       | `writeFloat`                                      |

Tags are packed as `(field_number << 3) | wireType`, then varint-encoded.
Zigzag for `sint32` is `(n << 1) ^ (n >> 31)`. Floats are written little-endian
via `Float.bitPattern`.

There is no `SwiftProtobuf` dependency in `Package.swift`. Why hand-roll?

- Only one outbound message shape is in use, so the encoder is ~60 lines.
- Avoids a build-time `protoc` step and a generated-Swift checked-in tree.
- Avoids pulling Apple's runtime into the BLE package.

The .proto schemas the watch expects are not authored by Compass; consult the
Gadgetbridge tree at `app/src/main/proto/` for the canonical definitions
(`Smart.proto`, `CoreService.proto`, etc.).

## PhoneLocation: bottom-up assembly

`PhoneLocationEncoder` builds a nested message structure and wraps the result
in a `PROTOBUF_RESPONSE` (5044) GFDI message:

```
Smart [field 13]
  └─ CoreService [field 7]
       └─ LocationUpdatedNotification [field 1]
            └─ LocationData
                 ├─ [1] LatLon { sint32 lat, sint32 lon }   semicircles
                 ├─ [2] altitude       float, metres
                 ├─ [3] timestamp      uint32, Garmin epoch
                 ├─ [4] h_accuracy     float, metres
                 ├─ [5] v_accuracy     float, metres
                 ├─ [6] position_type  enum (2 = REALTIME_TRACKING)
                 ├─ [9] bearing        float, degrees
                 └─ [10] speed         float, m/s
```

Compass: `PhoneLocation.swift:36-59`. The encoder builds inner messages first
and only then writes them as length-delimited fields in their parents — that
is the only correct way to encode nested protobuf messages without two-pass
length prefixing.

### Coordinate scale

Lat/lon are encoded as semicircles (matching the FIT type used elsewhere):

```swift
private static let semicircleScale: Double = 2_147_483_648.0 / 180.0  // 2³¹ / 180
let latSC = Int32(clamping: Int64(latDegrees * semicircleScale))
let lonSC = Int32(clamping: Int64(lonDegrees * semicircleScale))
```

Compass: `PhoneLocation.swift:21, 33-34`.

### `LatLon.sint32` vs. `LocationData.uint32` for timestamp

`lat` and `lon` use `sint32` (zigzag) because they are signed and frequently
negative. `timestamp` is `uint32` (Garmin epoch is always positive). Floats
(altitude, accuracies, bearing, speed) use wire type 5.

## Triggering: `PhoneLocationService`

`Compass/Services/PhoneLocationService.swift` owns a `CLLocationManager`,
asks for `whenInUse` authorization, and calls
`PhoneLocationEncoder.encode(...)` once per `didUpdateLocations` callback.
The resulting `GFDIMessage` is handed to `SyncCoordinator`'s injected
`sendMessage` closure (`PhoneLocationService.swift:11, 41-55`).

`startUpdatingLocation` immediately delivers the cached location via the
delegate, so the watch sees a fix as soon as it asks for one. The default
filters used are `kCLLocationAccuracyHundredMeters` and a 50 m
`distanceFilter` to keep the BLE traffic and battery cost reasonable.

The Garmin epoch offset is `631_065_600` Unix seconds
(`PhoneLocationService.swift:13, 57-59`).

## References

- Compass: `Packages/CompassBLE/Sources/CompassBLE/Utils/ProtoEncoder.swift`
- Compass: `Packages/CompassBLE/Sources/CompassBLE/GFDI/Messages/PhoneLocation.swift`
- Compass: `Compass/Services/PhoneLocationService.swift`
- Compass: `Packages/CompassBLE/Sources/CompassBLE/Public/GarminDeviceManager.swift:222-239`
- Gadgetbridge: `app/src/main/proto/` — canonical `.proto` files
- Gadgetbridge: `ProtobufStatusMessage.java`, `GarminSupport.onSetGpsLocation`
- Gadgetbridge reference: [`../references/gadgetbridge-pairing.md`](../references/gadgetbridge-pairing.md) §17

Source: [`ProtoEncoder.swift`](../../../Packages/CompassBLE/Sources/CompassBLE/Utils/ProtoEncoder.swift),
[`PhoneLocation.swift`](../../../Packages/CompassBLE/Sources/CompassBLE/GFDI/Messages/PhoneLocation.swift),
[`PhoneLocationService.swift`](../../../Compass/Services/PhoneLocationService.swift).
