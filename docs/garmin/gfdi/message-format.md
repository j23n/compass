# GFDI Wire Format

The Garmin Flexible and Interoperable Data Interface (GFDI) is the
application-level message protocol that runs **on top of** the V2 Multi-Link
(ML) transport. After the ML handshake assigns Compass a GFDI handle, every
byte that flows over that handle is a GFDI frame produced by the layout below.

> Decoded GFDI bytes only become available once the lower stack
> (CompassBLE → BluetoothCentral → MultiLinkTransport) has stripped the ML
> handle byte and run COBS decoding. See `docs/garmin/transport/` for the
> ML/COBS layer.

## Frame Layout

```
+--------+--------+----------------+--------+
| length | type   | payload (var.) | crc16  |
+--------+--------+----------------+--------+
   2 LE     2 LE       length-6        2 LE
```

| Offset | Size | Field   | Notes                                                                                       |
| -----: | ---: | ------- | ------------------------------------------------------------------------------------------- |
|      0 |    2 | length  | UInt16 LE. **Total** byte count of the frame, **including** the length field itself. Min 6. |
|      2 |    2 | type    | UInt16 LE message type (see [message-types.md](message-types.md)).                          |
|      4 |  N-6 | payload | Type-specific bytes; may be empty.                                                          |
|    N-2 |    2 | crc16   | Garmin nibble-table CRC-16 over `length` + `type` + `payload` (i.e. the first `N-2` bytes).  |

A frame with no payload is exactly 6 bytes long. The watch rejects frames
where `length` disagrees with the byte stream or where the CRC fails.

Compass: `GFDIMessage.swift:43-66` (encode) and `GFDIMessage.swift:92-141`
(decode). The CRC is the **Garmin nibble-table CRC-16** (`CRC16.compute`);
this is the same algorithm used in FIT files and ANT-FS, **not**
CRC-16/CCITT — see [`../transport/crc16.md`](../transport/crc16.md) for
the full algorithm and constants. Gadgetbridge: `ChecksumCalculator.java`.

## Compact Type Encoding

When the high bit of the type word is set, the watch is using a 1-byte
shorthand: the actual decimal type is `(raw & 0x00FF) + 5000`. Compass folds
this back transparently during decode:

```swift
var rawType = UInt16(data[start + 2]) | (UInt16(data[start + 3]) << 8)
if rawType & 0x8000 != 0 {
    rawType = (rawType & 0x00FF) &+ 5000
}
```

Compass: `GFDIMessage.swift:106-111`. Reference: Gadgetbridge
`GFDIMessage.java#parseIncoming`. Compass never *emits* the compact form on
egress — it always writes the full 16-bit decimal type.

## CRC-16

The frame CRC is the **Garmin nibble-table CRC-16** — a custom 16-entry
table algorithm shared with FIT files and ANT-FS, **not** CRC-16/CCITT.
Constants `[0x0000, 0xCC01, 0xD801, 0x1400, …]`; each input byte is folded
through the table twice (low nibble, then high nibble). See
[`../transport/crc16.md`](../transport/crc16.md) for the full algorithm and
test vectors.

Compass: `CRC16.swift`. Validated on every decode
(`DecodeError.crcMismatch`).

## RESPONSE (5000) Wrapping

`RESPONSE` (`0x1388`) is the universal ACK/NACK envelope. Its payload is
itself structured:

| Offset | Size | Field             | Notes                                                                                                |
| -----: | ---: | ----------------- | ---------------------------------------------------------------------------------------------------- |
|      0 |    2 | originalType      | UInt16 LE — the type code being acknowledged.                                                        |
|      2 |    1 | status            | `0=ACK`, `1=NACK`, `2=UNSUPPORTED`, `3=DECODE_ERROR`, `4=CRC_ERROR`, `5=LENGTH_ERROR`.               |
|      3 |    K | additionalPayload | Per-`originalType` extension. Empty for a bare ACK. See below for known shapes.                      |

So a "bare" ACK is a 9-byte frame on the wire:
`length(2) + type=0x1388(2) + originalType(2) + status=0(1) + crc(2)`.

Compass: `Response.swift:13-75`. Status codes mirror Gadgetbridge
`GFDIStatusMessage.Status`.

### Known Extended Status Payloads

Some incoming messages require non-trivial extra bytes after `status` or the
watch will retransmit every ~1 s until it gets a satisfactory reply. Compass
implements these inline in `GarminDeviceManager.handleUnsolicited`.

#### DEVICE_INFORMATION echo (host → watch — **NOT used by Compass**)

`DeviceInformationResponse` builds a full host-info echo (Compass:
`DeviceInformation.swift:89-148`):

```
[hostProtocolVersion: UInt16 LE]
[hostProductNumber:   UInt16 LE]
[hostUnitNumber:      UInt32 LE]
[hostSoftwareVersion: UInt16 LE]
[hostMaxPacketSize:   UInt16 LE]
[bluetoothName:       length-prefixed UTF-8]
[manufacturer:        length-prefixed UTF-8]
[device:              length-prefixed UTF-8]
[protocolFlags:       UInt8]
```

**Compass deviation:** the runtime path sends a **bare 9-byte ACK** for
DEVICE_INFORMATION, matching real Gadgetbridge behaviour against the
Instinct Solar 1G. The full echo path is test-only. See
[pairing.md](pairing.md) and `GarminDeviceManager.swift:445-447`.

#### AUTH_NEGOTIATION echo

`additionalPayload`: `[authNegStatus: UInt8][unknown: UInt8][authFlags: UInt32 LE]`.
`authNegStatus` is `0=GUESS_OK` or `1=GUESS_KO`. The `unknown` byte and
`authFlags` are echoed back from the incoming message. Compass:
`AuthNegotiation.swift:42-82`.

#### CURRENT_TIME_REQUEST reply

Required during the post-pair burst or the watch stays in the setup wizard.
`additionalPayload` (Compass: `GarminDeviceManager.swift:399-429`):

```
[referenceID:           UInt32 LE]   // echoed from inbound
[garminTimestamp:       UInt32 LE]   // unix - 631_065_600
[tzOffsetSec:           UInt32 LE]
[nextTransitionEnds:    UInt32 LE]   // 0 (Compass does not compute DST)
[nextTransitionStarts:  UInt32 LE]   // 0
```

#### PROTOBUF_REQUEST reply

The watch sends `PROTOBUF_REQUEST` (0x13B3) and expects a RESPONSE — *not* a
PROTOBUF_RESPONSE (0x13B4). `additionalPayload` (Compass:
`GarminDeviceManager.swift:222-239`):

```
[requestId:    UInt16 LE]
[dataOffset:   UInt32 LE]   // 0
[chunkStatus:  UInt8]       // 0 = KEPT
[statusCode:   UInt8]       // 0 = NO_ERROR
```

#### MUSIC_CONTROL_CAPABILITIES reply

`additionalPayload`: `[count: UInt8][commandOrdinals: count × UInt8]`
listing every `GarminMusicControlCommand` ordinal Compass supports.
Compass: `GarminDeviceManager.swift:241-252`.

#### NOTIFICATION_SUBSCRIPTION reply

`additionalPayload`: `[notificationStatus: UInt8 = 0 ENABLED][enableEcho: UInt8][unk: UInt8 = 0]`.
A bare ACK leaves the watch retransmitting every second. Compass:
`GarminDeviceManager.swift:281-300`.

## CONFIGURATION (5050) Capability Bitmask

Symmetric format used by both directions:

```
[length: UInt8][capabilityBytes: length]
```

Bits map to `GarminCapability` ordinals (LSB-first within each byte). Compass
sends 15 bytes of `0xFF` (`Configuration.swift:37-46`); the specific bits
the Instinct cares about during pairing are not publicly documented, so
all-1s is the safest superset.

## SET_DEVICE_SETTINGS (5026) TLV Payload

```
[count: UInt8]
[
  [settingType: UInt8]
  [valueLength: UInt8]
  [value:       valueLength bytes]
] × count
```

`valueLength` is `1` for booleans, `4` for `int32`, or the UTF-8 byte count
for strings. Compass: `PostInit.swift:30-93`.

## Endianness

Every multi-byte integer in GFDI is little-endian. UTF-8 strings are
length-prefixed with a single byte (truncated to 255 bytes). Compass:
`DeviceInformation.swift:152-185` (helpers).

## See Also

- [message-types.md](message-types.md) — full type code table.
- [pairing.md](pairing.md) — handshake order using these frames.
- [system-events.md](system-events.md) — SYSTEM_EVENT (5030) payload.

## Source

- Compass: `Packages/CompassBLE/Sources/CompassBLE/GFDI/GFDIMessage.swift`,
  `MessageTypes.swift`, `Messages/Response.swift`,
  `Messages/Configuration.swift`, `Messages/PostInit.swift`,
  `Messages/DeviceInformation.swift`,
  `Public/GarminDeviceManager.swift`.
- Gadgetbridge: `GFDIMessage.java`, `GFDIStatusMessage.java`,
  `ConfigurationMessage.java`.
- `docs/garmin/references/gadgetbridge-pairing.md` §§ 5, 7, 8.
