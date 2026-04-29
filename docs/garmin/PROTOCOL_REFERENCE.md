# BLE Protocol Reference

This document describes the Bluetooth Low Energy protocol used by Garmin fitness watches, as reverse-engineered by the Gadgetbridge project. Compass reimplements this protocol in Swift in the `CompassBLE` package.

Primary reference: [Gadgetbridge source](https://codeberg.org/Freeyourgadget/Gadgetbridge) at `app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/garmin/`.

## BLE service and characteristics

Garmin devices expose multiple GATT service variants. The Instinct Solar and other modern devices use the V2 Multi-Link service.

### Known Garmin service UUIDs

| Variant   | UUID                                     | Devices              |
|-----------|------------------------------------------|----------------------|
| V2 (ML)   | `6A4E2800-667B-11E3-949A-0800200C9A66`  | Instinct Solar, Forerunner 265, Fenix 7, etc. |
| V1        | `6A4E2401-667B-11E3-949A-0800200C9A66`  | Vivomove HR, older    |
| V0        | `9B012401-BC30-CE9A-E111-0F67E491ABDE`  | Vivofit, FR620        |

### V2 Multi-Link characteristics (primary)

| Item                   | UUID                                     |
|-----------------------|------------------------------------------|
| Service               | `6A4E2800-667B-11E3-949A-0800200C9A66`   |
| Write (phone → watch) | `6A4E2820-667B-11E3-949A-0800200C9A66`   |
| Notify (watch → phone)| `6A4E2810-667B-11E3-949A-0800200C9A66`   |

Additional channels exist (2821/2811, 2822/2812, etc.) but are not needed for file sync.

### Scanning

Many Garmin devices do NOT advertise the service UUID in their BLE advertisement packet. Gadgetbridge scans for ALL BLE devices with no service filter, then matches by device name. Compass follows the same approach.

The phone writes to the write characteristic and subscribes to notifications on the notify characteristic. All communication is bidirectional through these two characteristics.

## MLR framing

MLR (Maximum Likelihood Ratio) is the low-level framing protocol that segments GFDI messages into BLE-MTU-sized packets. Each BLE write/notification contains one MLR frame.

### Frame layout

```
Offset  Size  Description
------  ----  -----------
0       1     Flags byte
1       N     Payload (partial or complete GFDI message)
```

### Flags byte

```
Bit 7-4: Reserved (0)
Bit 3:   First frame (1 = this is the first frame of a message)
Bit 2:   Last frame  (1 = this is the last frame of a message)
Bit 1-0: Reserved (0)
```

Common flag values:
- `0x0C` (bits 3+2): Single-frame message (both first and last)
- `0x08` (bit 3): First frame of a multi-frame message
- `0x00`: Continuation frame
- `0x04` (bit 2): Last frame of a multi-frame message

### Reassembly

The receiver accumulates payload bytes from consecutive frames. When a frame with the "last" bit set arrives, the accumulated buffer contains a complete GFDI message. The maximum MLR payload per frame is `MTU - 3` (ATT overhead) minus 1 (flags byte).

**Source**: `GarminByteBufferReader.java`

## GFDI message structure

GFDI (Garmin Flexible Data Interface) is the application-level protocol carried inside MLR frames.

### Message layout

```
Offset  Size     Description
------  -------  -----------
0       2        Message length (little-endian, includes all fields except itself)
2       2        Message type (little-endian)
4       N        Payload (variable, type-specific)
4+N     2        CRC-16 (Garmin nibble-table, over bytes 0 through 4+N-1)
```

Total message size = 2 (length) + length field value.

The CRC covers the length field, message type, and payload. **Not** standard CRC-16/CCITT —
Garmin uses a custom nibble-table algorithm shared with FIT files and ANT-FS. See
`CRC-16 implementation` below.

**Source**: `GFDIMessage.java`

## Message types

All known GFDI message type codes used by Compass. Source of truth: `MessageTypes.swift`.

Message type encoding: direct 16-bit LE. Additionally, if bit 15 is set in an incoming type
byte, the actual type = `(raw & 0xFF) + 5000` (compact encoding). `GFDIMessage.decode`
handles this transparently.

| Type (hex) | Type (dec) | Swift name                   | Direction           |
|-----------|------------|------------------------------|---------------------|
| 0x1388    | 5000       | `response`                   | Either (generic ACK/NACK) |
| 0x138A    | 5002       | `downloadRequest`            | Phone → Watch       |
| 0x138B    | 5003       | `uploadRequest`              | Phone → Watch       |
| 0x138C    | 5004       | `fileTransferData`           | Watch → Phone       |
| 0x138D    | 5005       | `createFile`                 | Phone → Watch       |
| 0x138F    | 5007       | `directoryFilter`            | Phone → Watch       |
| 0x1390    | 5008       | `setFileFlag`                | Phone → Watch       |
| 0x1393    | 5011       | `fitDefinition`              | Phone → Watch       |
| 0x1394    | 5012       | `fitData`                    | Phone → Watch       |
| 0x1396    | 5014       | `weatherRequest`             | Watch → Phone       |
| 0x13A0    | 5024       | `deviceInformation`          | Watch → Phone       |
| 0x13A2    | 5026       | `deviceSettings`             | Phone → Watch       |
| 0x13A6    | 5030       | `systemEvent`                | Phone → Watch       |
| 0x13A7    | 5031       | `supportedFileTypesRequest`  | Phone → Watch       |
| 0x13A9    | 5033       | `notificationUpdate`         | Phone → Watch       |
| 0x13AA    | 5034       | `notificationControl`        | Either              |
| 0x13AB    | 5035       | `notificationData`           | Either              |
| 0x13AC    | 5036       | `notificationSubscription`   | Phone → Watch       |
| 0x13AD    | 5037       | `synchronization`            | Watch → Phone       |
| 0x13AF    | 5039       | `findMyPhoneRequest`         | Watch → Phone       |
| 0x13B0    | 5040       | `findMyPhoneCancel`          | Watch → Phone       |
| 0x13B1    | 5041       | `musicControl`               | Watch → Phone       |
| 0x13B2    | 5042       | `musicControlCapabilities`   | Watch → Phone       |
| 0x13B3    | 5043       | `protobufRequest`            | Watch → Phone       |
| 0x13B4    | 5044       | `protobufResponse`           | Phone → Watch       |
| 0x13B9    | 5049       | `musicControlEntityUpdate`   | Phone → Watch       |
| 0x13BA    | 5050       | `configuration`              | Either              |
| 0x13BC    | 5052       | `currentTimeRequest`         | Watch → Phone       |
| 0x13ED    | 5101       | `authNegotiation`            | Watch → Phone       |

**Source**: `MessageTypes.swift` (`GFDIMessageType` enum).

## Authentication flow

AUTH_NEGOTIATION (5101) is **watch-initiated** and optional. The watch sends it
asynchronously after the CONFIGURATION exchange; it does not block the handshake.

```
Watch                                   Phone
  |                                       |
  |  AUTH_NEGOTIATION (5101)              |
  |  [unknown: UInt8]                     |
  |  [authFlags: UInt32 LE]               |
  |-------------------------------------->|
  |                                       |
  |  RESPONSE (5000) for AUTH_NEGOTIATION |
  |  [authNegStatus: 0 = GUESS_OK]        |
  |  [unknown: echoed back]               |
  |  [authFlags: echoed back]             |
  |<--------------------------------------|
```

There is no long-term key exchange, no user confirmation step, and no pairing-approved/rejected
flow. The phone simply echoes the incoming `unknown` byte and `authFlags` back with
`GUESS_OK (0)`. This is sufficient for all Instinct Solar pairing.

AUTH_NEGOTIATION may arrive during the handshake or afterwards; it is handled via the
unsolicited message handler either way.

**Source**: `AuthNegotiation.swift`, `AuthNegotiationMessage.java` (Gadgetbridge)

## File transfer flow

After authentication, the phone can request files from the watch. The typical flow is:

### 1. Request file directory

```
Phone                                   Watch
  |                                       |
  |  DirectoryFileFilterRequest           |
  |  (filterType=allKnownTypes)           |
  |-------------------------------------->|
  |                                       |
  |  FileReadyNotification                |
  |  (status=ready, dataID=<dirID>,       |
  |   dataSize=<size>)                    |
  |<--------------------------------------|
  |                                       |
  |  FileTransferDataRequest              |
  |  (dataID=<dirID>, offset=0,           |
  |   maxSize=<size>)                     |
  |-------------------------------------->|
  |                                       |
  |  FileTransferDataResponse             |
  |  (status=OK, data=<FIT directory>)    |
  |<--------------------------------------|
  |                                       |
  |  FileTransferDataReceivedAck          |
  |  (status=OK, dataID=<dirID>)          |
  |-------------------------------------->|
```

The directory is itself a FIT file. Parsing it yields a list of `FITDirectory` entries, each with a `dataType`, `fileNumber`, `dataID`, and `fileSize`.

### 2. Download individual files

For each file to download:

```
Phone                                   Watch
  |                                       |
  |  FileTransferDataRequest              |
  |  (dataID=<fileDataID>, offset=0,      |
  |   maxSize=<fileSize>)                 |
  |-------------------------------------->|
  |                                       |
  |  FileTransferDataResponse  (chunk 1)  |
  |  (status=OK,                          |
  |   data=<partial>, offset=0)           |
  |<--------------------------------------|
  |                                       |
  |  FileTransferDataReceivedAck          |
  |  (status=OK)                          |
  |-------------------------------------->|
  |                                       |
  |  FileTransferDataResponse  (chunk N)  |
  |  (status=OK,                          |
  |   data=<partial>, offset=<prev+len>)  |
  |<--------------------------------------|
  |                                       |
  |  FileTransferDataReceivedAck          |
  |  (status=OK)                          |
  |-------------------------------------->|
  |                                       |
  |  [Repeat until all bytes received]    |
```

Each `FileTransferDataResponse` carries a chunk of the file. The phone must acknowledge each chunk with `FileTransferDataReceivedAck` before the watch sends the next chunk. The transfer is complete when the total bytes received equals the file size from the directory entry.

### 3. File types

Directory entries use a `(dataType, subType)` pair. All FIT files have `dataType = 128 (0x80)`.
The `subType` determines content class. Values are `FileType` enum raw values in `FileMetadata.swift`.

| dataType/subType | Swift `FileType`  | Content |
|---|---|---|
| 128/4  | `.activity`      | Activity recording (run, ride, etc.) |
| 128/6  | `.course`        | Course / navigation route (upload only) |
| 128/32 | `.monitor`       | Daily monitoring envelope (msg 55, msg 233) |
| 128/44 | `.metrics`       | Aggregate health metric summaries |
| 128/49 | `.sleep`         | Sleep sessions (msgs 273–276, 382) |
| 128/58 | `.monitorHealth` | HSA archive — primary per-second health data on Instinct Solar |

**Source**: `FileMetadata.swift` (`FileType` enum), `FileType.java` (Gadgetbridge)

## Protobuf messages

GFDI types 5043 (`protobufRequest`) / 5044 (`protobufResponse`) carry Protocol Buffer
payloads for structured data exchange.

Compass uses a **hand-rolled `ProtoEncoder`** (`Utils/ProtoEncoder.swift`) rather than
the SwiftProtobuf library. It supports wire types 0 (varint/enum/sint32 zigzag), 2
(length-delimited: embedded messages and bytes), and 5 (32-bit float).

Current usage:
- **Incoming** `protobufRequest` (5043): ACKed with a `RESPONSE (5000)` carrying
  `[requestId LE][dataOffset=0][chunkStatus=0][statusCode=0]`. No full proto decode yet.
- **Outgoing** `PhoneLocation`: pushes GPS coordinates to the watch via
  `Smart.CoreService.LocationUpdatedNotification` using the hand-rolled encoder.

Proto definitions (for reference): Gadgetbridge repo at `app/src/main/proto/`.
See `PROTOBUF.md` for context on the hand-rolled approach.

**Source**: `ProtoEncoder.swift`, `PhoneLocation.swift`, `GarminDeviceManager.swift:handleUnsolicited`

## CRC-16 implementation

Garmin uses a **custom nibble-table CRC-16** — the same algorithm used in FIT files and
ANT-FS. It is **not** CRC-16/CCITT (polynomial 0x1021); using the wrong algorithm produces
a CRC silently rejected by the watch.

Each input byte is split into two 4-bit nibbles, each folded through a 16-entry constant
table:

```swift
// See CompassBLE/Utils/CRC16.swift
private static let constants: [UInt16] = [
    0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
    0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400,
]

static func compute(data: Data, seed: UInt16 = 0) -> UInt16 {
    var crc = seed
    for byte in data {
        crc = ((crc >> 4) & 0x0FFF) ^ constants[Int(crc & 0x0F)] ^ constants[Int(byte & 0x0F)]
        crc = ((crc >> 4) & 0x0FFF) ^ constants[Int(crc & 0x0F)] ^ constants[Int((byte >> 4) & 0x0F)]
    }
    return crc
}
```

The `seed` parameter enables running-CRC for chunked file transfers: pass the previous
call's return value as seed for each subsequent chunk.

**Source**: `CRC16.swift`, `ChecksumCalculator.java` (Gadgetbridge), Garmin FIT SDK
