# GFDI File Sync — Upload (phone → watch)

This document specifies the byte-level wire protocol Compass uses to push files
(today: GPX-derived FIT courses) onto a Garmin watch over BLE. Source of truth:
the Swift implementation in `Packages/CompassBLE/Sources/CompassBLE/`. Where
Compass diverges from the Java reference, it is called out explicitly.

Cross-references:
- Transport framing: `../transport/`
- GFDI envelope: `./message-format.md`
- Sister doc (download direction): `./file-sync-download.md`
- Authoritative reference: `../references/gadgetbridge-sync.md` §§ 4–9, 13, 14

All multi-byte fields are little-endian unless noted. Driver:
`FileUploadSession.swift` — `upload(data:progress:)`.

---

## 1. Sequence overview

```
phone                                                              watch
  |                                                                  |
  | (1) CreateFile (5005, size, nonce, masks) ──────────────────────→|
  |     CreateFileStatus  ←─────────────────────── RESPONSE(5000)    |
  |          (returns assigned fileIndex)                            |
  |                                                                  |
  | (2) UploadRequest (5003, fileIndex, size) ─────────────────────→|
  |     UploadRequestStatus ←─────────────────── RESPONSE(5000)      |
  |          (validates dataOffset==0, maxFileSize ≥ size)           |
  |                                                                  |
  | (3) phone subscribes to .response                                |
  |     for each chunk c0..cN:                                       |
  |       FileTransferData (5004, flags, CRC, offset, data) ───────→|
  |       per-chunk ACK (RESPONSE 5000, original=5004) ←─────────────|
  |       [filter on originalType — drop unrelated RESPONSEs]        |
  |     phone unsubscribes from .response                            |
  |                                                                  |
  | (4) SystemEvent(SYNC_COMPLETE) ─────────────────────────────────→|
  |     watch archives the new file itself; no SetFileFlag needed    |
```

Five logical steps total. CreateFile and UploadRequest are both synchronous
`sendAndWait(awaitType: .response)`. Per-chunk ACKs use a **persistent
subscription**, not `sendAndWait`, because unrelated RESPONSE frames during the
slow BLE writes would resolve a one-shot continuation prematurely
(`FileUploadSession.swift:103–157`).

---

## 2. CreateFileMessage (5005, phone → watch)

Total payload: **22 bytes**. Verified in source: `CourseUpload.swift:38–50`.

| Offset | Size | Field         | Compass value | Notes                                  |
|-------:|-----:|---------------|---------------|----------------------------------------|
| 0      | 4    | fileSize      | data.count    | total bytes about to be uploaded       |
| 4      | 1    | fileDataType  | 128 (0x80)    | FIT                                    |
| 5      | 1    | fileSubType   | 6             | course                                 |
| 6      | 2    | fileIndex     | 0             | "let watch assign"                     |
| 8      | 1    | reserved      | 0             |                                        |
| 9      | 1    | subtypeMask   | 0             | not used for course uploads            |
| 10     | 2    | numberMask    | 0xFFFF        | sentinel                               |
| 12     | 2    | unknown       | 0             | Gadgetbridge sends 0                   |
| 14     | 8    | nonce         | random        | non-zero, `SecRandomCopyBytes`         |

The 8-byte nonce is required to be non-zero; Compass fills it with
`SecRandomCopyBytes(kSecRandomDefault, 8, ...)`
(`CourseUpload.swift:32–35`). All field roles "verified in source".

---

## 3. CreateFileStatus (RESPONSE 5000, originalType=5005)

Awaited as `awaitType: .response` (full RESPONSE frame).
Verified in source: `CourseUpload.swift:88–106`, `FileUploadSession.swift:53–62`.

Payload after RESPONSE header:

| Offset | Size | Field         | Notes                                                  |
|-------:|-----:|---------------|--------------------------------------------------------|
| 0      | 2    | originalType  | 5005                                                   |
| 2      | 1    | outerStatus   | 0 = success                                            |
| 3      | 1    | createStatus  | 0=OK, 1=DUPLICATE, 2=NO_SPACE, 3=UNSUPPORTED, 4=NO_SLOTS |
| 4      | 2    | fileIndex     | **assigned by watch** — use for UploadRequest          |
| 6      | 1    | fileDataType  | echo of request (128)                                  |
| 7      | 1    | fileSubType   | echo of request (6)                                    |
| 8      | 2    | fileNumber    | watch-assigned file number                             |

`canProceed` requires `outerStatus == 0 && createStatus == .ok`.

---

## 4. UploadRequestMessage (5003, phone → watch)

Total payload: **12 bytes**. Verified in source: `CourseUpload.swift:122–141`.

| Offset | Size | Field      | Compass value          | Notes                              |
|-------:|-----:|------------|------------------------|------------------------------------|
| 0      | 2    | fileIndex  | from CreateFileStatus  |                                    |
| 2      | 4    | dataSize   | data.count             | total bytes to upload              |
| 6      | 4    | dataOffset | 0                      | always start from beginning        |
| 10     | 2    | crcSeed    | 0                      | seed for the running upload CRC    |

---

## 5. UploadRequestStatus (RESPONSE 5000, originalType=5003)

Verified in source: `CourseUpload.swift:163–202`,
`FileUploadSession.swift:73–94`.

| Offset | Size | Field         | Notes                                                       |
|-------:|-----:|---------------|-------------------------------------------------------------|
| 0      | 2    | originalType  | 5003                                                        |
| 2      | 1    | outerStatus   | 0 = success                                                 |
| 3      | 1    | uploadStatus  | 0=OK, 1=INDEX_UNKNOWN, 2=INDEX_NOT_WRITEABLE,               |
|        |      |               | 3=NO_SPACE, 4=INVALID, 5=NOT_READY, 6=CRC_INCORRECT         |
| 4      | 4    | dataOffset    | next byte watch expects (must be 0 for fresh upload)        |
| 8      | 4    | maxFileSize   | **slot's max total file size** — NOT the per-chunk size     |
| 12     | 2    | crcSeed       | seed echo                                                   |

`canProceed` requires `outerStatus == 0 && uploadStatus == .ok && dataOffset == 0`.
Compass also enforces `data.count <= maxFileSize` and rejects oversized files
(`FileUploadSession.swift:89–94`).

### 5a. The maxFileSize-vs-chunk-size pitfall (commit `81d8156`)

> **Compass-critical bug fix.** A naive reading of the response treats
> `maxFileSize` as the per-chunk size; that field is actually the slot's total
> capacity, often tens of KB. Sending the entire file as a single GFDI frame
> overflows ML reassembly on the watch and the upload silently fails.

Compass therefore computes the per-chunk size from the ML-negotiated
`maxPacketSize` (default 375), with a 13-byte deduction for GFDI overhead:

```swift
let effectiveChunkSize = self.maxPacketSize - 13
```

The 13 bytes break down as:

```
2 size + 2 type + 1 flags + 2 chunkCRC + 4 offset + 2 frameCRC
```

Verified in source: `FileUploadSession.swift:96–100`. See also the inline
comment in `CourseUpload.swift:158–162`.

---

## 6. FileTransferDataChunk (5004, phone → watch)

Same wire layout as the watch → phone direction (`FileTransferDataMessage` in
the download doc). Field order is **flags, chunkCRC, dataOffset, data** —
reversing CRC and offset causes the watch to parse `dataOffset` as the CRC and
respond with `transferStatus=4 (offsetMismatch), nextDataOffset=0`. Documented
inline at `CourseUpload.swift:218–221`.

| Offset | Size | Field      | Notes                                                       |
|-------:|-----:|------------|-------------------------------------------------------------|
| 0      | 1    | flags      | 0x00=middle, 0x08=last, 0x0C=abort                          |
| 1      | 2    | chunkCRC   | running CRC of all bytes sent so far (incl. this chunk)     |
| 3      | 4    | dataOffset | absolute byte offset of this chunk                          |
| 7      | rest | data       | chunk payload, ≤ `maxPacketSize - 13` bytes                 |

Verified in source: `CourseUpload.swift:223–250`.

### 6a. Running CRC

Compass uses `FITCRC.compute(data, seed: previousCRC)` — the canonical Garmin
FIT CRC-16, not the GFDI frame CRC. The seed for chunk 0 is 0 (matches
`crcSeed` from UploadRequest), and each chunk's CRC becomes the seed for the
next:

```swift
runningCRC = FITCRC.compute(Data(chunkData), seed: runningCRC)
```

Verified in source: `FileUploadSession.swift:117–125`, table at `:204–211`.

### 6b. Flags

| Value | Meaning      | When                                              |
|------:|--------------|---------------------------------------------------|
| 0x00  | middle chunk | every chunk except the last                       |
| 0x08  | last chunk   | when `chunkEnd >= data.count`                     |
| 0x0C  | abort        | sent on the error path before unsubscribing       |

Verified in source: `CourseUpload.swift:224–228`, `FileUploadSession.swift:120–122, 181–187`.

---

## 7. FileTransferDataUploadACK (RESPONSE 5000, originalType=5004)

Per-chunk ACK from the watch. Same byte layout as the download direction's
`FileTransferDataACK`. Verified in source: `CourseUpload.swift:264–294`.

| Offset | Size | Field          | Notes                                              |
|-------:|-----:|----------------|----------------------------------------------------|
| 0      | 2    | originalType   | 5004                                               |
| 2      | 1    | outerStatus    | 0                                                  |
| 3      | 1    | transferStatus | 0=OK, 1=RESEND, 2=ABORT, 3=CRC_MISMATCH, 4=OFFSET_MISMATCH |
| 4      | 4    | nextDataOffset | first byte the watch expects next                  |

Compass advances `offset = ack.nextDataOffset` after each ACK and breaks out of
the chunk loop when `isLast == true` (`FileUploadSession.swift:163–174`).

### 7a. Why a persistent subscription, not sendAndWait

```swift
let ackStream = await client.subscribe(to: .response)
// ... per chunk:
//   send chunk
//   for await responseMsg in ackStream {
//     if originalType != 5004 { skip }
//     return decode(responseMsg)
//   }
```

Reasons (`FileUploadSession.swift:103–157`):

1. The ML BLE write is slow; an unrelated RESPONSE arriving in the middle would
   resolve a one-shot `sendAndWait(.response)` continuation with the wrong frame.
2. Filtering on `originalType == 5004` discards delayed RESPONSEs from previous
   operations or watch-initiated protocol messages.
3. A 15-second per-chunk timeout is enforced via `withThrowingTaskGroup` racing
   the ack-receive task against `Task.sleep`.

---

## 8. Completion: SystemEvent(SYNC_COMPLETE)

After the last chunk's ACK, Compass unsubscribes from `.response` and sends a
`SystemEventMessage(eventType: .syncComplete)`. The send is best-effort
(`try?`). Verified in source: `FileUploadSession.swift:188–193`.

> **Course uploads do NOT issue `SetFileFlag`.** The watch handles archive
> bookkeeping itself for newly-created files. This differs from the download
> path where each downloaded file is explicitly archived.

---

## 9. Error path — abort flow

Any thrown error inside the chunk loop runs the catch block:

```swift
let abortChunk = FileTransferDataChunk(
    flags: .abort,             // 0x0C
    dataOffset: offset,        // last known offset
    chunkCRC: runningCRC,
    data: Data()               // empty payload
)
try? await client.send(message: abortChunk.toMessage())
await client.unsubscribe(from: .response)
throw error
```

Verified in source: `FileUploadSession.swift:180–190`. The watch interprets the
empty 0x0C-flagged frame as "abandon this slot".

---

## 10. End-to-end byte budget — worked example

For an `N`-byte course at the default ML `maxPacketSize=375`:

```
effectiveChunkSize  = 375 - 13           = 362 bytes
chunks              = ceil(N / 362)
last chunk size     = N - 362 * (chunks - 1)
total RESPONSE ACKs = chunks
```

For a 12 KB course (`N=12288`):

| Quantity            | Value      |
|---------------------|------------|
| chunks              | 34         |
| middle-chunk size   | 362 B      |
| last-chunk size     | 354 B      |
| middle-chunk frame  | 362 + 13 = 375 B (matches ML budget) |
| ACKs received       | 34         |

---

## 11. FileType note (upload direction)

Today only `course` (subType=6, dataType=128) is exercised. The CreateFile
payload hard-codes `fileDataType=128, fileSubType=6` in
`CreateFileMessage.toMessage` (`CourseUpload.swift:23–24, 41–42`); other
subtypes are not exercised by Compass and would need separate verification
against the Gadgetbridge reference before use.

---

## 12. Field-by-field verification matrix

| Symbol                                | Source                                 | Status                       |
|---------------------------------------|----------------------------------------|------------------------------|
| `CreateFileMessage` (22 bytes)        | `CourseUpload.swift:38–50`             | verified in source           |
| 8-byte non-zero `nonce`               | `CourseUpload.swift:32–35`             | verified in source           |
| `subtypeMask=0`, `numberMask=0xFFFF`  | `CourseUpload.swift:45–46`             | verified in source           |
| `CreateFileStatus.decode`             | `CourseUpload.swift:88–106`            | verified in source           |
| `UploadRequestMessage` (12 bytes)     | `CourseUpload.swift:122–141`           | verified in source           |
| `UploadRequestStatus.decode`          | `CourseUpload.swift:186–202`           | verified in source           |
| `effectiveChunkSize = maxPacketSize-13` | `FileUploadSession.swift:96–100`     | verified in source (commit 81d8156) |
| Field order flags/CRC/offset/data     | `CourseUpload.swift:218–221, 242–249`  | verified in source           |
| Flags 0x00 / 0x08 / 0x0C              | `CourseUpload.swift:224–228`           | verified in source           |
| Cumulative `chunkCRC` (FITCRC)        | `FileUploadSession.swift:117–125`      | verified in source           |
| Persistent `.response` ACK loop       | `FileUploadSession.swift:103–157`      | verified in source           |
| `originalType==5004` filter           | `FileUploadSession.swift:139–145`      | verified in source           |
| 15s per-chunk timeout via TaskGroup   | `FileUploadSession.swift:150–156`      | verified in source           |
| Abort chunk on error path             | `FileUploadSession.swift:180–190`      | verified in source           |
| Final `SystemEvent(SYNC_COMPLETE)`    | `FileUploadSession.swift:193`          | verified in source           |
| No `SetFileFlag` for course upload    | (absence)                              | verified in source           |

---

## Source

- `Packages/CompassBLE/Sources/CompassBLE/GFDI/Messages/CourseUpload.swift`
- `Packages/CompassBLE/Sources/CompassBLE/Sync/FileUploadSession.swift`
- `Packages/CompassBLE/Sources/CompassBLE/Sync/FileMetadata.swift` (FileType enum)
- `Packages/CompassBLE/Sources/CompassBLE/Public/SyncProgress.swift`

Reference (authoritative for any field marked "from Gadgetbridge reference"):
- `docs/garmin/references/gadgetbridge-sync.md` §§ 4–9, 13, 14
