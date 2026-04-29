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
4+N     2        CRC-16 (CCITT, over bytes 0 through 4+N-1)
```

Total message size = 2 (length) + length field value.

The CRC covers the length field, message type, and payload. It uses the CRC-16/CCITT polynomial (0x1021) with initial value 0x0000.

**Source**: `GFDIMessage.java`

## Message types

The following table lists the GFDI message types relevant to Compass. Message types come in request/response pairs where the response type is the request type + 1.

| Type (hex) | Type (dec) | Name                              | Direction     |
|-----------|------------|-----------------------------------|---------------|
| 0x138C    | 5004       | ProtobufRequest                   | Phone -> Watch |
| 0x138D    | 5005       | ProtobufResponse                  | Watch -> Phone |
| 0x1392    | 5010       | DeviceInformationRequest          | Phone -> Watch |
| 0x1393    | 5011       | DeviceInformationResponse         | Watch -> Phone |
| 0x1396    | 5014       | SystemEventNotification           | Watch -> Phone |
| 0x1398    | 5016       | AuthNegotiationRequest            | Phone -> Watch |
| 0x1399    | 5017       | AuthNegotiationResponse           | Watch -> Phone |
| 0x139E    | 5022       | FileTransferDataRequest           | Phone -> Watch |
| 0x139F    | 5023       | FileTransferDataResponse          | Watch -> Phone |
| 0x13A0    | 5024       | CreateFileRequest                 | Phone -> Watch |
| 0x13A1    | 5025       | CreateFileResponse                | Watch -> Phone |
| 0x13A2    | 5026       | DirectoryFileFilterRequest        | Phone -> Watch |
| 0x13A3    | 5027       | DirectoryFileFilterResponse       | Watch -> Phone |
| 0x13A8    | 5032       | FileTransferDataReceivedAck       | Phone -> Watch |
| 0x13AC    | 5036       | FileReadyNotification             | Watch -> Phone |
| 0x13B0    | 5040       | SupportedFileTypesRequest         | Phone -> Watch |
| 0x13B1    | 5041       | SupportedFileTypesResponse        | Watch -> Phone |

**Source**: `GFDIMessage.java` and subclasses in the `messages/` directory.

## Authentication flow

Authentication establishes a trusted connection between the phone and the watch. It must complete before any file transfers can occur.

```
Phone                                   Watch
  |                                       |
  |  1. Connect BLE                       |
  |-------------------------------------->|
  |                                       |
  |  2. Discover service + characteristics|
  |-------------------------------------->|
  |                                       |
  |  3. Subscribe to notify characteristic|
  |-------------------------------------->|
  |                                       |
  |  4. AuthNegotiationRequest            |
  |  (longTermKeyAvailable=false,         |
  |   status=pairingRequest)              |
  |-------------------------------------->|
  |                                       |
  |  5. AuthNegotiationResponse           |
  |  (status=pairingApproved/Rejected)    |
  |<--------------------------------------|
  |                                       |
  |  [If approved, user confirms on watch]|
  |                                       |
  |  6. AuthNegotiationRequest            |
  |  (longTermKeyAvailable=true,          |
  |   longTermKey=<256-bit key>)          |
  |-------------------------------------->|
  |                                       |
  |  7. AuthNegotiationResponse           |
  |  (status=paired)                      |
  |<--------------------------------------|
  |                                       |
  |  [Connection authenticated]           |
```

For subsequent connections where a long-term key is already stored:

```
Phone                                   Watch
  |                                       |
  |  1. Connect + discover + subscribe    |
  |-------------------------------------->|
  |                                       |
  |  2. AuthNegotiationRequest            |
  |  (longTermKeyAvailable=true,          |
  |   longTermKey=<stored key>)           |
  |-------------------------------------->|
  |                                       |
  |  3. AuthNegotiationResponse           |
  |  (status=paired)                      |
  |<--------------------------------------|
```

The long-term key is a 256-bit value that should be stored securely (e.g., iOS Keychain) and associated with the device's BLE identifier.

**Source**: `AuthNegotiationMessage.java`

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

Common FIT file types found on Garmin watches:

| dataType | Description                                        |
|---------|----------------------------------------------------|
| 0       | Device settings                                     |
| 2       | Sport/activity settings                             |
| 3       | Activity (workout) files                            |
| 4       | Workout templates                                   |
| 6       | Course files                                        |
| 10      | Goals                                               |
| 32      | Monitoring (daily health metrics -- HR, steps, etc.)|
| 64      | Sleep                                               |
| 128     | HRV                                                 |

For Compass, the primary interest is types 3 (activity), 32 (monitoring), 64 (sleep), and 128 (HRV).

**Source**: `FileTransferHandler.java`, `GarminSupport.java`

## Protobuf messages

Some GFDI messages (type 5004/5005) carry protobuf-encoded payloads for structured data exchange. These are used for:

- Weather data (phone -> watch)
- Music control (watch -> phone)
- Notification service
- Device settings sync
- Find my phone

The `.proto` definitions are in the Gadgetbridge repository under `app/src/main/proto/`. See `docs/PROTOBUF.md` for regeneration instructions.

**Source**: `ProtobufMessage.java`, proto files under `app/src/main/proto/`

## CRC-16 implementation

The GFDI CRC uses CRC-16/CCITT:

- Polynomial: `0x1021`
- Initial value: `0x0000`
- Input/output reflection: No
- Final XOR: `0x0000`

```swift
// Reference implementation (see CompassBLE/Utils/CRC16.swift)
func crc16(_ data: [UInt8]) -> UInt16 {
    var crc: UInt16 = 0x0000
    for byte in data {
        crc ^= UInt16(byte) << 8
        for _ in 0..<8 {
            if crc & 0x8000 != 0 {
                crc = (crc << 1) ^ 0x1021
            } else {
                crc = crc << 1
            }
        }
    }
    return crc
}
```

**Source**: `ChecksumCalculator.java` in Gadgetbridge
