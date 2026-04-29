# Garmin Course Upload Protocol

## Overview

The Garmin GFDI (Gadgetbridge File Delivery Interface) supports uploading course files from phone to watch. This document specifies the binary protocol, FIT course file format, and message structures for uploading a GPX course as a navigable route on the Instinct Solar.

---

## BLE Upload Protocol (5-Step Flow)

### Step 1: CreateFile Handshake

The phone initiates by sending a **CreateFileMessage** to advertise the incoming file's size, type, and metadata.

**Phone → Watch: CreateFileMessage (type 5005 = 0x1388 + 0x1277)**

```
[UInt32 LE] fileSize          Total bytes of the FIT file payload
[UInt8]     fileDataType      128 (FILE_COURSES)
[UInt8]     fileSubType       6 (COURSE)
[UInt16 LE] fileIndex         0 (let watch assign)
[UInt8]     reserved          0
[UInt8]     subtypeMask       0
[UInt16 LE] numberMask        0xFFFF
[UInt16 LE] unknown           0 (observed from GadgetBridge)
[8 bytes]   nonce             Random (SecRandomCopyBytes); must be non-zero
```

**Total payload: 22 bytes**

**Watch → Phone: RESPONSE(0x1388) containing CreateFileStatus**

The watch responds with a generic RESPONSE frame wrapping the status (see "Message Wrapping" below).

```
[UInt8]     status            0 = success, non-zero = error
[UInt8]     createStatus      0=OK, 1=DUPLICATE, 2=NO_SPACE, 3=UNSUPPORTED, 4=NO_SLOTS
[UInt16 LE] fileIndex         Assigned index for subsequent upload messages
[UInt8]     fileDataType      Echo: 128
[UInt8]     fileSubType       Echo: 6
[UInt16 LE] fileNumber        File number on watch
```

**Errors:**
- `createStatus == 1` (DUPLICATE): A course with this name already exists. Offer user to rename.
- `createStatus == 2` (NO_SPACE): Watch storage full. Suggest deleting an unused course.
- `createStatus > 2`: Unsupported file type or no file slots. Unrecoverable.

---

### Step 2: UploadRequest

Once the file is created, the phone sends an UploadRequestMessage to initiate the chunked data transfer.

**Phone → Watch: UploadRequestMessage (type 5003)**

```
[UInt16 LE] fileIndex         From CreateFileStatus
[UInt32 LE] dataSize          Total FIT file bytes (same as fileSize from Step 1)
[UInt32 LE] dataOffset        0 (we always start at offset 0; supports resume but not used here)
[UInt16 LE] crcSeed           0 (initialize CRC16 with this seed; 0 means start fresh)
```

**Total payload: 12 bytes**

**Watch → Phone: RESPONSE(0x1388) containing UploadRequestStatus**

```
[UInt8]     status            0 = success
[UInt8]     uploadStatus      0=OK, 1=INDEX_UNKNOWN, 3=NO_SPACE
[UInt32 LE] dataOffset        Expected next offset (must be 0 if status is OK)
[UInt32 LE] maxPacketSize     Max bytes per chunk (typically 375–512 for Instinct)
[UInt16 LE] crcSeed           Returned CRC seed (confirm against request)
```

If `uploadStatus != 0`, abort with a user error.

---

### Step 3: Chunk Subscription

Before sending chunks, the phone subscribes to RESPONSE messages to receive per-chunk ACKs from the watch.

```swift
let subscription = try await gfdiClient.subscribe(awaitType: .response)
```

---

### Step 4: Chunked Upload

The phone splits the FIT file into chunks sized to fit within `maxPacketSize - 13` (13 bytes = overhead of flags, offset, CRC).

For each chunk:

**Phone → Watch: FileTransferDataChunk**

```
[UInt8]     flags           0x00 = middle chunk, 0x08 = final chunk, 0x0C = abort
[UInt32 LE] dataOffset      Byte offset of this chunk in the file
[UInt16 LE] chunkCRC        Running CRC16 over bytes sent *so far* (inclusive of this chunk)
[N bytes]   data            Chunk payload (max: maxPacketSize - 13)
```

**Encoding Details:**
- `chunkCRC` is computed by:
  1. Start with `seed = 0` (or the returned `crcSeed` from UploadRequestStatus).
  2. For each chunk, compute `chunkCRC = CRC16.compute(data: chunkData, seed: previousCRC)`.
  3. Include this running CRC in every chunk (the watch uses it to validate data integrity).

**Watch → Phone: RESPONSE(0x1388) with DataOffset (ACK)**

After receiving each chunk, the watch responds with a RESPONSE containing:

```
[UInt8]     status          0 = success, non-zero = error
[UInt32 LE] nextDataOffset  Byte offset for the next chunk (should match your next offset; if not, the watch is requesting retransmit)
```

- If `nextDataOffset < expectedOffset`, the watch is asking for a retransmit of the last chunk. Resend it.
- If `nextDataOffset > expectedOffset`, the watch skipped ahead or there is a protocol error. Stop and error.
- Continue looping until `nextDataOffset >= data.count`.

---

### Step 5: Upload Complete

Once all chunks are sent (last chunk had `flags = 0x08`), send a **SystemEventMessage** to signal completion.

**Phone → Watch: SystemEventMessage(event: .syncComplete)**

The watch acknowledges implicitly (no separate response). The course is now on the watch and ready to use.

---

## Message Wrapping (RESPONSE Quirk)

Unlike compact-typed download responses (DownloadRequestStatus), the Instinct Solar wraps `CreateFileStatus` and `UploadRequestStatus` inside a full `RESPONSE(0x1388)` frame.

**Decoding CreateFileStatus:**

```swift
if let response = try GFDIResponse.decode(from: reader) {
    let payloadReader = ByteReader(data: response.payload)
    let createStatus = try CreateFileStatus.decode(from: payloadReader)
}
```

Same pattern for `UploadRequestStatus`.

---

## FIT Course File Format

A course FIT file is a binary time-series database with a specific message sequence. Below is the encoding for the Instinct Solar.

### FIT File Structure

```
[14 bytes]  File Header
[N bytes]   Definition & Data Messages (body)
[2 bytes]   Trailing CRC16
```

### Header (14 bytes, LE)

```
[UInt8]     headerSize      14 (or 12 in compact mode; we use 14)
[UInt8]     protocolVersion 16
[UInt16 LE] profileVersion  2134 (typically Garmin SDK version, not strictly validated)
[UInt32 LE] dataSize        Byte count of body (definition + data messages) **excluding** CRC
[4 bytes]   dataType        ".FIT" (0x2E 0x46 0x49 0x54)
```

**Note:** `dataSize` is the length of the body only (messages + definitions), not the header or trailing CRC.

### Message Sequence

#### 1. File ID Definition & Data

**Definition Message (local type 0):**

Defines the structure of global message type 0 (file_id). The watch uses this to extract the course's metadata.

```
[UInt8]     reservedByte    0
[UInt8]     architecture    0 (little-endian)
[UInt16 LE] globalMsgType   0 (file_id)
[UInt8]     numFields       5
[UInt8]     field[0].defNum     0 (type)
[UInt8]     field[0].size       1 byte
[UInt8]     field[0].baseType   0 (UInt8)
[UInt8]     field[1].defNum     1 (manufacturer)
[UInt8]     field[1].size       2 bytes
[UInt8]     field[1].baseType   0x84 (UInt16 LE)
[UInt8]     field[2].defNum     2 (product)
[UInt8]     field[2].size       2 bytes
[UInt8]     field[2].baseType   0x84 (UInt16 LE)
[UInt8]     field[3].defNum     3 (time_created)
[UInt8]     field[3].size       4 bytes
[UInt8]     field[3].baseType   0x86 (UInt32 LE)
[UInt8]     field[4].defNum     4 (serial_number)
[UInt8]     field[4].size       4 bytes
[UInt8]     field[4].baseType   0x86 (UInt32 LE)
```

**Data Message (local type 0):**

```
[UInt8]     type            6 (COURSE)
[UInt16 LE] manufacturer    255 (invalid mfr; Garmin uses this as a marker for synthetic files)
[UInt16 LE] product         1 (generic)
[UInt32 LE] time_created    Garmin epoch (seconds since 1989-12-31 00:00:00 UTC)
[UInt32 LE] serial_number   0 (not used; can be watch serial or 0)
```

#### 2. Course Definition & Data

**Definition Message (local type 1, global type 31 = course):**

```
[UInt8]     reservedByte    0
[UInt8]     architecture    0
[UInt16 LE] globalMsgType   31
[UInt8]     numFields       1
[UInt8]     field[0].defNum     0 (name)
[UInt8]     field[0].size       16 bytes
[UInt8]     field[0].baseType   7 (String)
```

**Data Message (local type 1):**

```
[16 bytes]  name            Course name, UTF-8, null-padded to 16 bytes
```

#### 3. Lap Definition & Data

**Definition Message (local type 2, global type 19 = lap):**

```
[UInt8]     reservedByte    0
[UInt8]     architecture    0
[UInt16 LE] globalMsgType   19
[UInt8]     numFields       8
[UInt8]     field[0].defNum     0 (event)
[UInt8]     field[0].size       1
[UInt8]     field[0].baseType   0 (UInt8)
[UInt8]     field[1].defNum     1 (event_type)
[UInt8]     field[1].size       1
[UInt8]     field[1].baseType   0
[UInt8]     field[2].defNum     2 (start_time)
[UInt8]     field[2].size       4
[UInt8]     field[2].baseType   0x86 (UInt32 LE, Garmin epoch)
[UInt8]     field[3].defNum     254 (timestamp)
[UInt8]     field[3].size       4
[UInt8]     field[3].baseType   0x86 (UInt32 LE)
[UInt8]     field[4].defNum     3 (start_position_lat)
[UInt8]     field[4].size       4
[UInt8]     field[4].baseType   0x85 (Int32 LE, semicircles)
[UInt8]     field[5].defNum     4 (start_position_long)
[UInt8]     field[5].size       4
[UInt8]     field[5].baseType   0x85
[UInt8]     field[6].defNum     7 (total_distance)
[UInt8]     field[6].size       4
[UInt8]     field[6].baseType   0x86 (UInt32 LE, centimeters)
[UInt8]     field[7].defNum     10 (total_elapsed_time)
[UInt8]     field[7].size       4
[UInt8]     field[7].baseType   0x86 (UInt32 LE, milliseconds)
```

**Data Message (local type 2):**

```
[UInt8]     event                0 (TIMER)
[UInt8]     event_type           0 (START)
[UInt32 LE] start_time           Garmin epoch (import time)
[UInt32 LE] timestamp            Garmin epoch
[Int32 LE]  start_position_lat   Semicircles (first waypoint)
[Int32 LE]  start_position_long  Semicircles (first waypoint)
[UInt32 LE] total_distance       Course distance in centimeters
[UInt32 LE] total_elapsed_time   Course duration in milliseconds (0 for static course)
```

#### 4. Record Messages (one per waypoint)

**Definition Message (local type 3, global type 20 = record):**

```
[UInt8]     reservedByte    0
[UInt8]     architecture    0
[UInt16 LE] globalMsgType   20
[UInt8]     numFields       6
[UInt8]     field[0].defNum     254 (timestamp)
[UInt8]     field[0].size       4
[UInt8]     field[0].baseType   0x86
[UInt8]     field[1].defNum     0 (position_lat)
[UInt8]     field[1].size       4
[UInt8]     field[1].baseType   0x85
[UInt8]     field[2].defNum     1 (position_long)
[UInt8]     field[2].size       4
[UInt8]     field[2].baseType   0x85
[UInt8]     field[3].defNum     2 (altitude)
[UInt8]     field[3].size       2
[UInt8]     field[3].baseType   0x84 (UInt16 LE)
[UInt8]     field[4].defNum     3 (distance)
[UInt8]     field[4].size       4
[UInt8]     field[4].baseType   0x86
[UInt8]     field[5].defNum     5 (cadence) — optional, can omit
[UInt8]     field[5].size       1
[UInt8]     field[5].baseType   0 (UInt8)
```

**Data Messages (one per waypoint, local type 3):**

For each waypoint in order:

```
[UInt32 LE] timestamp           Garmin epoch (or sequential, 1 s apart)
[Int32 LE]  position_lat        Semicircles
[Int32 LE]  position_long       Semicircles
[UInt16 LE] altitude            (altitude + 500) * 5, clamped to [0, 65535]
[UInt32 LE] distance            Cumulative distance from start in centimeters
[UInt8]     cadence             0 (unused for courses)
```

#### 5. Course Point Messages (if course has named waypoints)

**Definition Message (local type 4, global type 32 = course_point):**

```
[UInt8]     reservedByte    0
[UInt8]     architecture    0
[UInt16 LE] globalMsgType   32
[UInt8]     numFields       6
[UInt8]     field[0].defNum     254 (timestamp)
[UInt8]     field[0].size       4
[UInt8]     field[0].baseType   0x86
[UInt8]     field[1].defNum     0 (position_lat)
[UInt8]     field[1].size       4
[UInt8]     field[1].baseType   0x85
[UInt8]     field[2].defNum     1 (position_long)
[UInt8]     field[2].size       4
[UInt8]     field[2].baseType   0x85
[UInt8]     field[3].defNum     2 (distance)
[UInt8]     field[3].size       4
[UInt8]     field[3].baseType   0x86
[UInt8]     field[4].defNum     4 (type)
[UInt8]     field[4].size       1
[UInt8]     field[4].baseType   0 (UInt8)
[UInt8]     field[5].defNum     3 (name)
[UInt8]     field[5].size       16
[UInt8]     field[5].baseType   7 (String)
```

**Data Messages (one per named waypoint):**

```
[UInt32 LE] timestamp           Garmin epoch
[Int32 LE]  position_lat        Semicircles
[Int32 LE]  position_long       Semicircles
[UInt32 LE] distance            Distance from start in centimeters
[UInt8]     type                0 (GENERIC)
[16 bytes]  name                Waypoint name, null-padded to 16 bytes
```

---

## Field Encodings

### Semicircles (for latitude / longitude)

Garmin encodes lat/lon as semicircles: a 32-bit signed integer where 2^31 semicircles = 180°.

```swift
func degreesToSemicircles(_ degrees: Double) -> Int32 {
    return Int32(degrees * (pow(2.0, 31) / 180.0))
}

func semicirclesToDegrees(_ semicircles: Int32) -> Double {
    return Double(semicircles) / (pow(2.0, 31) / 180.0)
}
```

### Altitude

Altitudes are encoded as `UInt16` where the value is `(altitude_meters + 500) * 5`, with a valid range of [0, 65535] representing roughly [-500m, 12558m].

```swift
func encodeAltitude(_ meters: Double) -> UInt16 {
    let scaled = (meters + 500.0) * 5.0
    return UInt16(max(0, min(65535, scaled)))
}

func decodeAltitude(_ encoded: UInt16) -> Double {
    return Double(encoded) / 5.0 - 500.0
}
```

### Distance

Distances are encoded as `UInt32` in centimeters.

```swift
func encodeDistance(_ meters: Double) -> UInt32 {
    return UInt32(meters * 100.0)
}
```

### Time (Elapsed & Timestamp)

- **Elapsed time:** milliseconds (UInt32)
- **Timestamp:** seconds since Garmin epoch (1989-12-31 00:00:00 UTC)

```swift
func garminEpochFromDate(_ date: Date) -> UInt32 {
    let garminEpoch = Date(timeIntervalSince1970: 631065600)  // 1989-12-31
    return UInt32(date.timeIntervalSince(garminEpoch))
}
```

---

## Trailing CRC

After the last data message, compute a CRC16 over the entire message body (all definitions + data messages, **excluding** the header). Append the CRC as a 2-byte little-endian value.

```swift
let bodyCRC = CRC16.compute(data: messageBody, seed: 0)
// Append bodyCRC.littleEndianBytes to the file
```

The Garmin CRC16 uses a nibble-based lookup table (see CompassFIT `CRC16.swift`). Both the phone and watch validate this CRC to detect corruption.

---

## Example Minimum FIT File (3 Waypoints)

```
Header:                    [14 bytes]  0x0E 0x10 0x6A 0x08 (magic) ...
Definition (local 0):      [12 bytes]  file_id structure
Data (file_id):            [15 bytes]  type=6, mfr=255, ...
Definition (local 1):      [10 bytes]  course structure
Data (course):             [16 bytes]  "My Route\0\0\0\0\0\0\0\0"
Definition (local 2):      [26 bytes]  lap structure
Data (lap):                [35 bytes]  start_time, lat, lon, distance, elapsed
Definition (local 3):      [20 bytes]  record structure
Data (record) × 3:         [39 bytes]  waypoint 1, 2, 3
[Trailing CRC]:            [2 bytes]   CRC16
```

Total file size: ~200 bytes for a minimal course.

---

## Known Issues & Quirks

1. **DUPLICATE courses:** If a course with the same name exists, the watch returns `createStatus = 1`. Offer the user to retry with a different name or overwrite.

2. **Nonce must be non-zero:** The 8-byte nonce field in CreateFileMessage must contain at least some non-zero bytes. Use `SecRandomCopyBytes` to fill it.

3. **CRC validation is strict:** If the trailing CRC does not match, the watch silently rejects the file. Always validate locally before sending.

4. **Chunk order matters:** Chunks must arrive in order. If a chunk arrives out of order, the watch stops and waits. Retry the out-of-order chunk.

5. **Watch assignment of fileIndex:** The fileIndex returned in CreateFileStatus is dynamically assigned by the watch. Store it and use it for all subsequent UploadRequest and chunk messages.

6. **Large courses (1000+ waypoints):** May take 200–300 chunks. Use a progress callback to notify the UI. There is no timeout per chunk (the protocol is ACK-driven), so slow transfers are safe.

---

## References

- **GadgetBridge course upload:** https://github.com/Freeyourgadget/Gadgetbridge/blob/master/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/garmin/GarminSupport.java
- **FIT SDK:** https://developer.garmin.com/fit/overview/
- **Instinct Solar manual:** https://www8.garmin.com/manuals/webhelp/instinctsolargps/EN-US/GUID-DFE3B88C-87C7-4FE1-AADC-FA925EB8FCC5.html
