# WP-2 · Sync Correctness & File Handling — Implementation Plan

## Summary of Issues

| Item | Status | Root Cause | Severity |
|---|---|---|---|
| Empty first sync / double-sync | Unfixed | Race condition between watch- and phone-initiated syncs; files archived mid-cancelled-sync; second sync finds nothing | HIGH |
| Hanging transfer when backgrounded | Unfixed | No timeout on chunk reception; `AsyncStream` iteration doesn't respond to app suspension | HIGH |
| Archive-after-receive (not after-processing) | Unfixed | `archiveFile()` called immediately after download at line 95, before parsing; failed parse = permanent data loss | CRITICAL |
| Parallel file-transfer handles | Deferred | Not required for correctness | — |

---

## Implementation Order

1. **Task 1 — Archive-after-processing** (most critical; data loss risk)
2. **Task 2 — Fix double-sync race condition** (depends on understanding archive flow; fix archive first)
3. **Task 3 — Chunk-receive timeout** (independent; fixes background hang)

---

## Task 1 — Archive-After-Processing, Not After-Receive

**Risk: MEDIUM** — Requires an architectural change across the BLE/app layer boundary. The `CompassBLE` package has no knowledge of parsing outcomes; `FileSyncSession` cannot call back into `SyncCoordinator`. The fix must thread the archive responsibility upward without creating a circular dependency.

### Root Cause

`FileSyncSession.run()` (`FileSyncSession.swift` ~line 91–101):

```swift
for entry in wanted {
    do {
        let url = try await downloadFile(entry: entry, progress: progress)
        downloadedURLs.append(url)
        try await archiveFile(entry: entry)   // ← BUG: archives before parsing
    } catch { /* skip */ }
}
```

Then separately, in `SyncCoordinator.processFITFiles()`, parsing happens. If parsing throws, the file was already archived on the watch and is gone forever.

### Fix: Deferred Archive Callback

**Architecture decision:** `FileSyncSession` returns a list of `(url: URL, entry: DirectoryEntry)` pairs. The caller (`GarminDeviceManager.pullFITFiles`) passes these to `SyncCoordinator` via the existing `syncCompletionHandler`. After parsing succeeds for a given URL, the coordinator calls back into the device manager to archive that specific file.

**Step A — `FileSyncSession.swift`**

Change the return type of `run()` from `[URL]` to `[(url: URL, entry: DirectoryEntry)]`:

```swift
func run(...) async throws -> [(url: URL, entry: DirectoryEntry)]
```

Remove the `archiveFile(entry:)` call from the per-file download loop entirely. The download loop now only downloads:

```swift
for entry in wanted {
    do {
        let url = try await downloadFile(entry: entry, progress: progress)
        downloadedURLs.append((url: url, entry: entry))
    } catch {
        BLELogger.sync.error("Sync: download failed for fileIndex=\(entry.fileIndex): \(error)")
    }
}
```

After the loop, call `archiveFile` for zero files (remove the existing archive calls). All archiving is now the caller's responsibility.

Also expose `archiveFile(entry:)` as `internal` (not `private`) so `GarminDeviceManager` can call it — or better: add an `archive(fileIndex:)` method to `FileSyncSession` that `GarminDeviceManager` can call after parsing.

Actually, cleaner approach: expose a new method on `GarminDeviceManager`:

```swift
public func archiveFITFile(fileIndex: UInt16) async
```

This creates a `FileSyncSession` (or reuses the GFDI client directly) to send `SetFileFlagsMessage`.

**Step B — `GarminDeviceManager.swift`**

Update `pullFITFiles()` to receive `[(url: URL, entry: DirectoryEntry)]` from `session.run()`.

Pass these pairs to the sync completion handler. Change the handler signature from `([URL]) async -> Void` to `([(url: URL, fileIndex: UInt16)]) async -> Void` (no need to expose `DirectoryEntry` outside CompassBLE).

Add a new public method:

```swift
public func archiveFITFile(fileIndex: UInt16) async {
    guard _isConnected, let client = gfdiClient else { return }
    let flagMsg = SetFileFlagsMessage(fileIndex: fileIndex).toMessage()
    _ = try? await client.sendAndWait(flagMsg, awaitType: .response, timeout: .seconds(5))
    BLELogger.sync.debug("Sync: archived fileIndex=\(fileIndex)")
}
```

Add `archiveFITFile(fileIndex:)` to `DeviceManagerProtocol` with a default no-op implementation.

**Step C — `SyncCoordinator.swift`**

Update `processWatchInitiatedURLs` and `processFITFiles` to receive `[(url: URL, fileIndex: UInt16)]`.

For each entry, after successfully saving to `FITFileStore` and inserting into SwiftData:

```swift
await deviceManager.archiveFITFile(fileIndex: fileIndex)
```

On parsing failure: do NOT call `archiveFITFile`. The file remains unarchived on the watch and will be re-downloaded on the next sync.

**Step D — `DeviceManagerProtocol.swift`**

- Update sync completion handler type: `(([(url: URL, fileIndex: UInt16)]) async -> Void)?`
- Add `func archiveFITFile(fileIndex: UInt16) async`

**Step E — `MockGarminDevice.swift`**

- Stub `archiveFITFile(fileIndex:)` as no-op.

### Migration Concern

If a sync is in progress when the app crashes mid-archive loop, some files in the batch will be archived and some will not. This is **correct behavior** — the un-archived files will be re-downloaded on the next sync, and the app-layer dedup logic (already in `SyncCoordinator`) will prevent duplicate SwiftData entries.

**Acceptance criteria:**
- Intentionally break the FIT parser for one file type; run a sync; that file type's files are NOT archived on the watch (verify by running another sync and seeing the same file listed again)
- After a successful parse, the file IS archived (verify by running another sync and seeing the file absent)
- No regressions in normal sync flow

---

## Task 2 — Fix Empty First Sync (Watch Directory Not Ready)

**Risk: LOW** — The fix is a self-contained retry inside `FileSyncSession.run()`. No protocol changes, no handler signature changes.

### Root Cause (Confirmed from log)

From `2026-05-01_double_sync_and_sleep.log`:

- **10:28:46** — "Sync Now" tapped; directory returns **1 entry**: `unknown(dt=1 st=0) 0B 1989-12-31` — zero-size, epoch timestamp, unrecognised type. Sync completes with 0 files (`skipped: 1 unknown type`).
- **10:28:52** — "Sync Now" tapped again (user frustration); same directory request returns **12 real entries**; 4 files downloaded successfully.

This is **not a race condition**. The watch returns a placeholder/stub directory entry immediately after waking from sleep, before its filesystem is ready. The real directory appears a few seconds later. The user had to tap twice to get real data.

The sentinel entry characteristics:
- `dataType=1, subType=0` — not a known FIT file type
- `size=0B`
- timestamp `1989-12-31` — Garmin epoch zero (Unix timestamp 0 = 1970-01-01 rendered as Garmin epoch offset)

### Fix: Auto-Retry on All-Unknown Directory

**`FileSyncSession.swift` — `run()`**

After parsing the directory, if all entries were skipped as unknown type (i.e., `wanted` is empty AND at least one entry existed), check whether the skip reason is "all unknown". If so, wait 4 seconds and re-request the directory once.

Add a helper to identify a "not-ready" directory result — a directory where every entry has `fitFileType == nil` and `size == 0`:

```swift
private func directoryLooksUnready(_ entries: [DirectoryEntry]) -> Bool {
    guard !entries.isEmpty else { return false }
    return entries.allSatisfy { $0.fitFileType == nil && $0.fileSize == 0 }
}
```

In `run()`, after filtering the directory:

```swift
var wanted = filterEntries(allEntries)

if wanted.isEmpty && directoryLooksUnready(allEntries) {
    BLELogger.sync.info("Sync: directory looks unready (all entries unknown/zero-size); retrying in 4s")
    try await Task.sleep(for: .seconds(4))
    let retryEntries = try await downloadDirectory()
    wanted = filterEntries(retryEntries)
    BLELogger.sync.info("Sync: retry directory has \(retryEntries.count) entries, \(wanted.count) wanted")
}
```

Only retry once. If the retry also returns nothing downloadable, proceed normally (sync completes with 0 files — legitimate if the watch genuinely has nothing new).

The 4-second delay matches the observed gap: the real directory appeared ~5.4 seconds after the first request (10:28:46 → 10:28:52 minus ~1 s for the second request's round-trip). 4 seconds is conservative enough to let the watch settle without making fast syncs feel slow.

**`SyncCoordinator.swift`** — no changes needed. The retry is transparent to the caller.

**Acceptance criteria:**
- Sync immediately after watch wakes from sleep: app waits 4 s, retries, gets real directory, downloads files — without user needing to tap twice
- Normal sync (watch already awake): 4-second wait does NOT fire (directory has real entries on first request)
- If watch genuinely has no new files: sync completes with 0 files immediately (no retry, since entries will either be archived or absent, not zero-size unknown)
- Log shows "directory looks unready; retrying in 4s" exactly once when the retry fires

---

## Task 3 — Fix Hanging Transfer When App Is Backgrounded

**Risk: LOW-MEDIUM** — The fix is additive (wrap existing loop with timeout); no protocol changes needed. However, the "correct" behavior when the app is backgrounded mid-transfer needs a policy decision: abort the transfer, or wait and hope BLE keeps the connection alive?

**Policy decision:** With WP-1 Task 7 in place (persistent background BLE), transfers should continue in background. Without it, they hang. The fix here addresses the hang regardless of WP-1 status by adding a per-chunk timeout.

### Root Cause

`FileSyncSession.downloadData()` (~line 232):

```swift
for await chunkMsg in chunkStream {
    // process chunk...
}
```

If the watch stops sending chunks (app backgrounded, BLE suspended, watch out of range), this loop waits forever. There is no timeout.

### Fix: Per-Chunk Timeout with `withThrowingTaskGroup`

**`FileSyncSession.swift` — `downloadData()`**

Replace the bare `for await` with a timeout wrapper. The simplest approach that preserves all existing chunk-processing logic:

```swift
private static let chunkTimeout: Duration = .seconds(30)

// Replace: for await chunkMsg in chunkStream {
// With:
while !Task.isCancelled {
    // Wait for next chunk with timeout
    let chunkMsg: FileTransferDataMessage = try await withTimeout(chunkTimeout) {
        var iterator = chunkStream.makeAsyncIterator()
        guard let msg = await iterator.next() else {
            throw SyncError.streamEnded
        }
        return msg
    }
    // ... existing chunk processing logic unchanged ...
}
```

The `withTimeout` helper (add as a file-private function in FileSyncSession.swift):

```swift
private func withTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw SyncError.chunkTimeout
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
```

Add `chunkTimeout` and `streamEnded` cases to `SyncError` (or use existing error types).

**Alternative (simpler):** Use `AsyncStream` with a dedicated timeout task that cancels the parent task after N seconds of inactivity. This is slightly simpler but less composable:

```swift
let timeoutTask = Task {
    try await Task.sleep(for: .seconds(30))
    chunkTask?.cancel()   // cancel the download task
}
defer { timeoutTask.cancel() }
// existing for-await loop unchanged, but outer task gets cancelled on timeout
```

Recommend the **`withThrowingTaskGroup` approach** for per-chunk precision.

**On timeout: send abort + SYNC_COMPLETE**

In the `catch SyncError.chunkTimeout` block (in `downloadData` or in `run()`):

```swift
catch SyncError.chunkTimeout {
    BLELogger.sync.warning("Sync: chunk timeout — aborting transfer")
    // Send abort ACK to watch
    let abortACK = FileTransferDataACK(transferStatus: .abort, crc: 0)
    _ = try? await client.send(message: abortACK.toMessage())
    throw SyncError.chunkTimeout
}
```

In `run()`, if `downloadData()` throws `chunkTimeout`, still send `SYNC_COMPLETE` so the watch doesn't hang:

```swift
} catch SyncError.chunkTimeout {
    BLELogger.sync.warning("Sync: sending SYNC_COMPLETE after timeout abort")
    try? await client.send(message: SystemEventMessage(eventType: .syncComplete).toMessage())
    throw   // re-throw to cancel the outer session
}
```

**Integration with WP-1 background work**

Once WP-1 Task 7 (persistent background BLE) is implemented, transfers should survive backgrounding automatically. The timeout here is a safety net for cases where BLE is unavoidably suspended (Airplane mode toggled, watch out of range, etc.) — not a workaround for the missing background entitlement.

**Acceptance criteria:**
- Background the app mid-transfer; within 30 s, the sync UI shows "failed" or "cancelled" (not stuck spinner)
- Watch does not remain in "syncing" state (its home screen returns within 30 s of the abort ACK)
- Foreground the app after timeout; a new "Sync Now" succeeds without needing a reconnect
- Normal sync (app in foreground) completes without triggering the timeout

---

## Protocol / Type Changes Summary

| Change | File | Notes |
|---|---|---|
| `FileSyncSession.run()` return type: `[URL]` → `[(url: URL, entry: DirectoryEntry)]` | `FileSyncSession.swift` | Breaks internal call site in `GarminDeviceManager` only |
| Remove `archiveFile()` calls from `run()` | `FileSyncSession.swift` | |
| New `GarminDeviceManager.archiveFITFile(fileIndex:)` | `GarminDeviceManager.swift` | |
| Add `archiveFITFile(fileIndex:)` to `DeviceManagerProtocol` | `DeviceManagerProtocol.swift` | Default no-op extension |
| Sync completion handler type: `([URL])` → `([(url: URL, fileIndex: UInt16)])` | `DeviceManagerProtocol.swift`, `GarminDeviceManager.swift`, `SyncCoordinator.swift` | |
| `SyncError.chunkTimeout`, `SyncError.streamEnded` | `FileSyncSession.swift` or shared error type | |
| `GarminDeviceManager.lastSyncCompleteDate` + debounce | `GarminDeviceManager.swift` | Private; no protocol change |

---

## Files to Modify

| File | Changes |
|---|---|
| `Packages/CompassBLE/Sources/CompassBLE/Sync/FileSyncSession.swift` | Remove archive calls from loop; change return type; add chunk timeout |
| `Packages/CompassBLE/Sources/CompassBLE/Public/GarminDeviceManager.swift` | Add `archiveFITFile()`; update `pullFITFiles()` for wait-not-cancel policy; add debounce |
| `Packages/CompassBLE/Sources/CompassBLE/Public/DeviceManagerProtocol.swift` | Add `archiveFITFile(fileIndex:)`; update handler type |
| `Packages/CompassBLE/Sources/CompassBLE/Public/MockGarminDevice.swift` | Stub `archiveFITFile()` |
| `Compass/App/SyncCoordinator.swift` | Update handler type; call `archiveFITFile` after successful parse |

---

## Known Risks

**Watch re-archives behavior:** Calling `archiveFITFile` per-file (after each successful parse) rather than in bulk at the end changes the archive timing. If the app crashes mid-batch, some files will be archived and some won't — which is the desired behavior. However, the watch may start compacting archived files immediately, so re-downloading a partially-processed batch may not be possible if the watch deletes archived files aggressively. Garmin Instinct Solar behavior here should be verified empirically.

**Double-sync debounce duration:** 5 seconds is a guess. If the watch normally re-sends `SYNCHRONIZATION` faster than this (e.g., within 2 s), the debounce needs to be tuned down. Capture logs to measure the real interval.

**Chunk timeout value (30 s):** This is conservative. BLE chunk intervals during a normal transfer are ~50–200 ms. A 30 s timeout means 150+ missed chunks before aborting — plenty of headroom for BLE retries, but slow enough to not fire on legitimate slow transfers. Tune based on observed transfer rates.
