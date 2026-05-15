# Sync errors: mishandled `downloadStatus=indexNotReadable`

When the watch responds to a `DOWNLOAD_REQUEST` (5002 / 0x138A) with
`downloadStatus=INDEX_NOT_READABLE` (or `INDEX_UNKNOWN`, `NO_SPACE_LEFT`,
`INVALID`, `NOT_READY`, `CRC_INCORRECT`) and `maxFileSize=0`, Compass
proceeds with the download loop as if the file were available. The
download then fails in confusing, cascading ways and contaminates
subsequent transfers in the same sync.

## Symptoms

From `compasslogs May 15 2026.txt` (build `0.1.0(1)`), within ~3 s:

```
09:32:19.369  Sync: file[136] monitor 1523B — DownloadRequestStatus
                  outerStatus=0 downloadStatus=indexNotReadable maxFileSize=0
09:32:19.369  Sync: file[136] monitor 1523B — downloading unknownB
09:32:19.369  Sync: file[136] monitor 1523B chunk #1 offset=0 size=502B …
09:32:20.839  ERROR  Sync: file[136] monitor 1523B chunk #1
                            offset mismatch expected=502 got=0
09:32:20.864  Sync: downloading file[129] monitor 476B
09:32:21.619  Sync: file[129] … DownloadRequestStatus … downloadStatus=ok …
09:32:21.620  ERROR  Sync: file[129] monitor 476B chunk #0
                            offset mismatch expected=0 got=502
```

Same shape for `file[53]` (`downloadStatus=noSpaceLeft`) at `09:32:23.287`,
which then sat in the chunk loop for ~31 s before the per-chunk timeout
triggered an abort:

```
09:32:54.157  WARNING  Sync: file[53] monitor 476B chunk timeout — aborting
09:32:54.159  WARNING  Sync: chunk timeout/stream-ended — sending SYNC_COMPLETE
```

## Root cause

`FileSyncSession.swift:236-243` only NACKs on the outer ACK byte
(`status != 0`), letting any non-`ok` `downloadStatus` through:

```swift
// Only gate on the outer ACK; some firmware returns non-zero downloadStatus
// even when proceeding (observed: status=3, maxFileSize=0 on Instinct Solar).
guard status.status == 0 else {
    throw SyncError.downloadFailed(…)
}
```

The comment was added because the Instinct Solar sometimes returns
`downloadStatus=3` (`NO_SPACE_LEFT`) but still sends the file. That carve-out
is too broad: it lets every non-zero `downloadStatus` proceed, including
`INDEX_NOT_READABLE` and `INDEX_UNKNOWN` where the watch sends nothing back.

When the watch sends nothing for the requested index but our handler is
still subscribed to `0x138C`, the next file's chunks (or stale fragments
from a previous transfer) get attributed to the wrong session and the
offset checks fire.

## Knock-on effect: `insufficientData` on adjacent requests

Same log, `file[155]` and `file[156]`:

```
09:32:18.108  ← GFDI type=0x1388 payloadLen=4   ← ACK for weather 0x1393
09:32:18.137  ERROR  Sync: skipping fileIndex=155 after error:
                            insufficientData(needed: 4, available: 0)
```

`FileSyncSession` calls
`client.sendAndWait(DownloadRequestMessage…, awaitType: .response, …)`. The
match is by GFDI type (`0x1388`), not by `originalType`. Any `RESPONSE`
arriving in the window — including ACKs for the immediately preceding
weather `FIT_DEFINITION` (5011) and `FIT_DATA` (5012) — satisfies the
wait. The "response" payload is then `93 13 00 00` (originalType=0x1393,
status=0) instead of the expected `8A 13 00 00 ⟨downloadStatus⟩
⟨maxFileSize×4⟩`. `DownloadRequestStatus.decode` skips the first two
bytes as if they were the originalType, then runs out of bytes when it
tries to read `maxFileSize`.

This race surfaces when sync runs concurrently with a watch-initiated
weather exchange, because both flows pump 0x1388 traffic on the same
link.

## Status

**Part 2 fixed** in `GFDIClient` — `sendAndWait(awaitType: .response)`
now derives the expected `originalType` from the outgoing message's
`type.rawValue` and registers in a separate `pendingResponses` dict
keyed by originalType. `routeMessage` peeks `payload[0..<2]` of every
incoming RESPONSE and prefers an originalType-specific waiter over
the generic `pendingContinuations[0x1388]` slot. Concurrent in-flight
requests no longer steal each other's ACKs, and the
`insufficientData` cascade on `file[155]` / `file[156]` from the
adjacent weather exchange is closed.

**Part 1 still open** — the `downloadStatus` gate in
`FileSyncSession.swift:238` still treats every non-zero outer status
as the only failure case, so an `indexNotReadable` reply with
`maxFileSize=0` will still take us into the chunk loop with nothing
to read. Filed as a separate piece of work.

## Proposed fix for Part 1

Tighten the gate in `FileSyncSession.swift:238`. Only proceed when
`downloadStatus ∈ {ok, noSpaceLeft}` (the latter for the Solar
workaround), and skip the file otherwise:

```swift
switch status.downloadStatus {
case .ok, .noSpaceLeft:
    break  // proceed
default:
    throw SyncError.downloadFailed(
        fileIndex: fileIndex,
        reason: "download refused: \(status.downloadStatus)"
    )
}
```

This converts the silent corruption into a clean per-file skip, the
same way `insufficientData` already does today. The directory walk
moves on to the next entry without contaminating the chunk stream.

## References

- `Packages/CompassBLE/Sources/CompassBLE/Sync/FileSyncSession.swift:222–249`
- `Packages/CompassBLE/Sources/CompassBLE/GFDI/Messages/FileSync.swift:105–158`
- Gadgetbridge: `service/devices/garmin/messages/status/DownloadRequestStatusMessage.java:15-29`
- Reference log: `compasslogs May 15 2026.txt` (build `0.1.0(1)`),
  lines 700–860, 1320–1450
