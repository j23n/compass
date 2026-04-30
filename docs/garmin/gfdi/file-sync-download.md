# GFDI File Sync — Download (watch → phone)

This document specifies the byte-level wire protocol Compass uses to read FIT
files off a Garmin watch over BLE (transport layer ML / COBS / GFDI). Source of
truth: the Swift implementation in `Packages/CompassBLE/Sources/CompassBLE/`,
which is what runs in the field and was validated against an Instinct Solar 1G.
Where Compass diverges from the Java reference, it is called out explicitly.

Cross-references:
- Transport framing: `../transport/`
- GFDI envelope (size/type/payload/CRC): `./message-format.md`
- Authoritative reference: `../references/gadgetbridge-sync.md` §§ 4–9, 13, 14
- Device quirks: `../instinct/device-reference.md`

All multi-byte fields are little-endian unless noted. "Verified in source"
markers point to the Swift symbol that constructs or parses the field today.

---

## 1. Sequence overview

```
phone                                                                watch
  |                                                                    |
  | (a) optional, only when the watch initiated the sync:              |
  |   SynchronizationMessage (5037)  ←─────────────────────────────────|
  |   FilterMessage (5007, byte=3)    ────────────────────────────────→|
  |   FilterStatus (compact 5007 ACK) ←────────────────────────────────|
  |                                                                    |
  | (b) directory pull:                                                |
  |   DownloadRequest (5002, fileIndex=0) ────────────────────────────→|
  |   DownloadRequestStatus  ←─────────────────── RESPONSE(5000)       |
  |   FileTransferData (5004) chunk 0 ←────────────────────────────────|
  |   FileTransferDataACK (RESPONSE 5000, original=5004) ─────────────→|
  |   ... repeat until last-chunk flag (0x08) or buffer == maxFileSize |
  |                                                                    |
  |   parse 16-byte DirectoryEntry rows                                |
  |                                                                    |
  | (c) per file (skipping isArchived rows):                           |
  |   DownloadRequest (5002, fileIndex=N) ────────────────────────────→|
  |   DownloadRequestStatus  ←─────────────────── RESPONSE(5000)       |
  |   FileTransferData × N      ←──────────────────────────────────────|
  |   FileTransferDataACK × N      ───────────────────────────────────→|
  |   SetFileFlag (5008, ARCHIVE=0x10) ───────────────────────────────→|
  |   SetFileFlagsStatus (RESPONSE 5000) ←─────────────────────────────|
  |                                                                    |
  | (d) end:                                                           |
  |   SystemEvent(SYNC_COMPLETE) ─────────────────────────────────────→|
```

Driver: `FileSyncSession.swift` — the `run(directories:progress:watchInitiated:)`
entry point.

---

## 2. SynchronizationMessage (5037, watch → phone)

Watch-initiated trigger. Compass parses but does not require it; phone-initiated
syncs skip step (a) and the FilterMessage.

| Offset | Size | Field         | Notes                                              |
|-------:|-----:|---------------|----------------------------------------------------|
| 0      | 1    | syncType      | 0/1/2 — semantics unknown, ignored                 |
| 1      | 1    | bitmaskSize   | 4 or 8                                             |
| 2      | N    | bitmask       | one bit per FileType ordinal, LE byte order        |

`shouldProceed` checks bits 3 (workouts), 5 (activities), 21 (activitySummary),
26 (sleep). Verified in source: `FileSync.swift:39–51`.

---

## 3. FilterMessage (5007, phone → watch)

Sent only on the watch-initiated path to consent to the sync. Compass models it
as a one-byte payload `0x03` ("UNK_3"). Verified in source: `FileSync.swift:61–67`.

| Offset | Size | Field    | Value | Notes                                       |
|-------:|-----:|----------|------:|---------------------------------------------|
| 0      | 1    | filterId | 0x03  | Always 3 — semantics unknown                |

> **Not exercised by Compass:** `FileReadyNotification` and
> `DirectoryFileFilterRequest` from the Gadgetbridge reference. Compass uses the
> minimal one-byte form above and never advertises a richer filter.

The reply is a compact-typed RESPONSE on type 5007; Compass treats it as a
liveness check and does not parse the payload (`FileSyncSession.swift:138–147`).

---

## 4. DownloadRequestMessage (5002, phone → watch)

| Offset | Size | Field        | Compass value | Notes                              |
|-------:|-----:|--------------|--------------:|------------------------------------|
| 0      | 2    | fileIndex    | 0 = directory | otherwise from DirectoryEntry      |
| 2      | 4    | dataOffset   | 0             | resume/CONTINUE not implemented    |
| 6      | 1    | requestType  | 0x01 (NEW)    | 0=CONTINUE, 1=NEW                  |
| 7      | 2    | crcSeed      | 0             | seed for the running CRC           |
| 9      | 4    | dataSize     | 0             | 0 = "send everything"              |

Total payload: 13 bytes. Verified in source: `FileSync.swift:94–102`.

---

## 5. DownloadRequestStatus (RESPONSE 5000, originalType=5002)

> **Compass quirk:** Compass awaits `awaitType: .response` (the full RESPONSE
> 0x1388 frame), NOT a compact-typed 0x138A frame. The Instinct Solar 1G never
> sends the compact form. Verified in source: `FileSyncSession.swift:222–228`.

Payload layout, after the 3-byte RESPONSE header `[origType: u16][outerStatus: u8]`:

| Offset | Size | Field          | Notes                                                     |
|-------:|-----:|----------------|-----------------------------------------------------------|
| 0      | 2    | originalType   | 5002                                                      |
| 2      | 1    | outerStatus    | 0 = ACK; only field Compass gates on                      |
| 3      | 1    | downloadStatus | 0=OK, 1=INDEX_UNKNOWN, 2=INDEX_NOT_READABLE, 3=NO_SPACE,  |
|        |      |                | 4=INVALID, 5=NOT_READY, 6=CRC_INCORRECT                   |
| 4      | 4    | maxFileSize    | total bytes the watch will push (0 = "unknown")           |

Verified in source: `FileSync.swift:145–158`.

> **Quirk:** Some Instinct Solar firmware reports `downloadStatus=3` (NO_SPACE)
> with `maxFileSize=0` and then proceeds to stream the file anyway. Compass
> therefore only gates on `outerStatus == 0` and falls back to the last-chunk
> flag for termination. See `../instinct/device-reference.md` and
> `FileSyncSession.swift:234–245`.

---

## 6. FileTransferDataMessage (5004, watch → phone)

One chunk of file body. The chunk size is whatever fits in the watch's outbound
ML packet — Compass does not advertise an expected size.

| Offset | Size | Field      | Notes                                                         |
|-------:|-----:|------------|---------------------------------------------------------------|
| 0      | 1    | flags      | bit 0x08 = "last chunk"; otherwise 0                          |
| 1      | 2    | chunkCRC   | running CRC of all bytes received so far (incl. this chunk)   |
| 3      | 4    | dataOffset | absolute byte offset of this chunk within the file            |
| 7      | rest | data       | chunk payload                                                 |

`chunkCRC` is **cumulative**, not per-chunk. Verify with
`CRC16.compute(data: chunk.data, seed: previousRunningCRC)` and feed the result
back as the next seed. Verified in source: `FileSync.swift:177–193` and
`FileSyncSession.swift:263–270`.

### Chunk-loop invariants

```swift
guard chunk.dataOffset == buffer.count else { offsetMismatch }
let computed = CRC16.compute(data: chunk.data, seed: runningCRC)
guard computed == chunk.chunkCRC else { crcMismatch }
runningCRC = computed
buffer.append(chunk.data)
sendACK(nextDataOffset: UInt32(buffer.count))
```

Termination: `expectedSize > 0 && buffer.count >= expectedSize`, OR
`(chunk.flags & 0x08) != 0`. When `maxFileSize == 0` the last-chunk flag is the
ONLY signal. Verified in source: `FileSyncSession.swift:286–292`.

---

## 7. FileTransferDataACK (phone → watch, per chunk)

Encoded as a full RESPONSE(5000) frame with `originalType = 5004`. Not compact.
Verified in source: `FileSync.swift:215–243`.

RESPONSE payload:

| Offset | Size | Field          | Value                                                    |
|-------:|-----:|----------------|----------------------------------------------------------|
| 0      | 2    | originalType   | 5004 (`fileTransferData`)                                |
| 2      | 1    | outerStatus    | 0 (ACK)                                                  |
| 3      | 1    | transferStatus | 0=OK, 1=RESEND, 2=ABORT, 3=CRC_MISMATCH,                 |
|        |      |                | 4=OFFSET_MISMATCH, 5=SYNC_PAUSED                         |
| 4      | 4    | nextDataOffset | first byte the phone expects next = `offset + len`       |

The watch resumes from `nextDataOffset`. On error, Compass sends
`transferStatus=.abort, nextDataOffset=buffer.count` BEFORE unsubscribing, so
in-flight chunks don't bleed into the next file's subscription
(`FileSyncSession.swift:306–313`).

---

## 8. DirectoryEntry — 16-byte directory rows

The body returned from `fileIndex=0` is a flat concatenation of 16-byte rows.
Compass parses them with `DirectoryEntry.parseAll`, which skips all-zero rows to
avoid the Gadgetbridge infinite-loop edge case
(`FileSync.swift:327–360`).

| Offset | Size | Field         | Notes                                                  |
|-------:|-----:|---------------|--------------------------------------------------------|
| 0      | 2    | fileIndex     | argument for subsequent DownloadRequest                |
| 2      | 1    | fileDataType  | 128 = FIT, 255 = other, 8 = DEVICE_XML                 |
| 3      | 1    | fileSubType   | see FileType table below                               |
| 4      | 2    | fileNumber    | type-specific, opaque                                  |
| 6      | 1    | specificFlags | type-specific, opaque                                  |
| 7      | 1    | fileFlags     | bit 0x10 = ARCHIVE (already synced)                    |
| 8      | 4    | fileSize      | total bytes                                            |
| 12     | 4    | fileTimestamp | Garmin epoch (seconds since 1989-12-31 00:00:00 UTC)   |

Garmin epoch → Unix: `+ 631_065_600` seconds. Verified in source:
`FileMetadata.swift:36–53`.

---

## 9. FileType table (subType when fileDataType == 128)

All 7 cases recognised by Compass. Verified in source: `FileMetadata.swift:65–105`.

| FileType         | subType (dec) | FITDirectory | Notes                                |
|------------------|--------------:|--------------|--------------------------------------|
| activity         | 4             | activity     | runs, rides, swims                   |
| course           | 6             | (n/a)        | upload-only direction                |
| monitor          | 32            | monitor      | HR/steps/stress snapshots            |
| activityVariant  | 41            | activity     | firmware variant of activity         |
| metrics          | 44            | metrics      | health-metric summaries              |
| sleep            | 49            | sleep        | sleep tracking                       |
| monitorHealth    | 58            | monitor      | Instinct Solar separate-file variant |

Rows whose `fileFlags & 0x10 != 0` are marked archived and skipped by the sync
session (`FileSyncSession.swift:71–78`).

---

## 10. SetFileFlagsMessage (5008, phone → watch) — ARCHIVE

After a successful per-file download Compass sets the ARCHIVE bit so the file
won't be re-offered.

| Offset | Size | Field     | Value                                          |
|-------:|-----:|-----------|------------------------------------------------|
| 0      | 2    | fileIndex | from the DirectoryEntry                        |
| 2      | 1    | flags     | 0x10 (ARCHIVE)                                 |

Verified in source: `FileSync.swift:258–276`.

The reply is a RESPONSE(5000) with `originalType=5008`. Compass awaits
`.response` (full frame, not compact) for symmetry with DownloadRequestStatus
and uses a 5-second timeout that is permitted to lapse silently
(`FileSyncSession.swift:323–329`).

---

## 11. SystemEvent(SYNC_COMPLETE)

Final phone → watch send after all per-file loops finish. Sent best-effort
(errors swallowed). Verified in source: `FileSyncSession.swift:111–112`.

---

## 12. Error path — abort flow

Any thrown error inside `downloadData` causes:

1. `FileTransferDataACK(transferStatus: .abort, nextDataOffset: buffer.count)`
   sent immediately, telling the watch to stop transmitting.
2. Synchronous unsubscribe from `.fileTransferData` BEFORE rethrowing — using
   `defer { Task { ... } }` would race the next file's subscribe.
3. The outer `run` loop swallows per-file errors and increments `failedCount`,
   so a single bad file does not abort the whole sync.

Verified in source: `FileSyncSession.swift:306–313`, `:99–109`.

---

## 13. Field-by-field verification matrix

| Symbol                                | Source                                            | Status                       |
|---------------------------------------|---------------------------------------------------|------------------------------|
| `SynchronizationMessage.decode`       | `FileSync.swift:39–51`                            | verified in source           |
| `FilterMessage.toMessage` (1 byte)    | `FileSync.swift:64–66`                            | verified in source           |
| `FileReadyNotification`               | (none)                                            | from Gadgetbridge ref, not exercised by Compass |
| `DirectoryFileFilterRequest`          | (none)                                            | from Gadgetbridge ref, not exercised by Compass |
| `DownloadRequestMessage`              | `FileSync.swift:94–102`                           | verified in source           |
| `DownloadRequestStatus.decode`        | `FileSync.swift:145–158`                          | verified in source           |
| `awaitType: .response` for 5002 reply | `FileSyncSession.swift:222–228`                   | verified in source (Instinct fix) |
| Chunk loop break condition            | `FileSyncSession.swift:286–292`                   | verified in source           |
| Cumulative `chunkCRC`                 | `FileSyncSession.swift:263–270`                   | verified in source           |
| `FileTransferDataACK` full RESPONSE   | `FileSync.swift:234–243`                          | verified in source           |
| `DirectoryEntry.parseAll`             | `FileSync.swift:327–360`                          | verified in source           |
| ARCHIVE flag (0x10)                   | `FileSync.swift:260`                              | verified in source           |
| Abort ACK on error path               | `FileSyncSession.swift:306–313`                   | verified in source           |
| `SystemEvent(SYNC_COMPLETE)` finish   | `FileSyncSession.swift:111–112`                   | verified in source           |

---

## Source

- `Packages/CompassBLE/Sources/CompassBLE/GFDI/Messages/FileSync.swift`
- `Packages/CompassBLE/Sources/CompassBLE/Sync/FileSyncSession.swift`
- `Packages/CompassBLE/Sources/CompassBLE/Sync/FileMetadata.swift`
- `Packages/CompassBLE/Sources/CompassBLE/Public/FITDirectory.swift`
- `Packages/CompassBLE/Sources/CompassBLE/Public/SyncProgress.swift`

Reference (authoritative for any field marked "from Gadgetbridge reference"):
- `docs/garmin/references/gadgetbridge-sync.md` §§ 4–9, 13, 14
- `docs/garmin/instinct/device-reference.md` (downloadStatus=3 quirk)
