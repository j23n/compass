import Foundation
import os

/// Runs a single complete file-sync session (directory listing + file downloads).
///
/// Create a fresh instance for each sync; discard when done.
///
/// Protocol summary (watch → phone):
/// ```
/// [watch-initiated only]
///   phone → FilterMessage (5007, byte=3)
///   watch → FilterStatus  (compact 5007 ACK)
///
/// phone → DownloadRequest (5002, fileIndex=0)         ← root directory
/// watch → DownloadRequestStatus (maxFileSize)
/// watch → FileTransferData (5004) × N                 ← directory body chunks
/// phone → FileTransferDataACK per chunk
/// phone parses 16-byte DirectoryEntry rows
///
/// for each matching file:
///   phone → DownloadRequest (5002, fileIndex=N)
///   watch → DownloadRequestStatus (maxFileSize)
///   watch → FileTransferData × N
///   phone → FileTransferDataACK per chunk
///   phone saves FIT bytes to temp file
///   phone → SetFileFlagsMessage (5008, ARCHIVE=0x10)
///   watch → SetFileFlagsStatus ACK
///
/// phone → SystemEvent(SYNC_COMPLETE)
/// ```
///
/// Reference: Gadgetbridge `FileTransferHandler.java`, `GarminSupport.java`.
actor FileSyncSession {

    private let client: GFDIClient
    private let maxPacketSize: Int

    /// Default per Gadgetbridge `FileTransferHandler.java:62`.
    init(client: GFDIClient, maxPacketSize: Int = 375) {
        self.client = client
        self.maxPacketSize = maxPacketSize
    }

    // MARK: - Entry point

    /// Run a complete sync and return local temp-file URLs for each downloaded FIT.
    ///
    /// - Parameters:
    ///   - directories: Which FIT directories to pull (activity / monitor / sleep / metrics).
    ///   - progress: Optional continuation for progress updates.
    ///   - watchInitiated: `true` when triggered by an incoming `SynchronizationMessage`;
    ///     the phone must send a `FilterMessage` handshake before requesting the directory.
    func run(
        directories: Set<FITDirectory>,
        progress: AsyncStream<SyncProgress>.Continuation?,
        watchInitiated: Bool = false
    ) async throws -> [URL] {
        let trigger = watchInitiated ? "watch-initiated" : "phone-initiated"
        let dirNames = directories.map(\.rawValue).sorted().joined(separator: ", ")
        BLELogger.sync.info("Sync: starting (\(trigger)) directories=[\(dirNames)]")
        progress?.yield(.starting)

        if watchInitiated {
            try await sendFilterAndWait()
        }

        // Download and parse the root directory.
        let allEntries = try await downloadDirectory(progress: progress)

        // Filter to the requested file types, skip already-archived files.
        var wanted: [DirectoryEntry] = []
        for entry in allEntries {
            if entry.isArchived {
                BLELogger.sync.debug(
                    "Sync: skipping fileIndex=\(entry.fileIndex) — already archived"
                )
                continue
            }
            guard let ft = entry.fitFileType else {
                BLELogger.sync.debug(
                    "Sync: skipping fileIndex=\(entry.fileIndex) — dataType=\(entry.fileDataType) subType=\(entry.fileSubType) not a known FIT type"
                )
                continue
            }
            guard let fileDir = ft.directory, directories.contains(fileDir) else {
                BLELogger.sync.debug(
                    "Sync: skipping fileIndex=\(entry.fileIndex) — type=\(ft) not in requested directories"
                )
                continue
            }
            wanted.append(entry)
        }

        BLELogger.sync.info("Sync: \(wanted.count) file(s) to download (of \(allEntries.count) in directory)")

        var downloadedURLs: [URL] = []
        var failedCount = 0

        for entry in wanted {
            do {
                let url = try await downloadFile(entry: entry, progress: progress)
                downloadedURLs.append(url)
                try await archiveFile(entry: entry)
            } catch {
                // Per Gadgetbridge: skip failed files, don't abort the whole sync.
                BLELogger.sync.error("Sync: skipping fileIndex=\(entry.fileIndex) after error: \(error)")
                failedCount += 1
            }
        }

        // Signal sync completion to the watch.
        try? await client.send(message: SystemEventMessage(eventType: .syncComplete).toMessage())

        logSyncSummary(
            allEntries: allEntries,
            wanted: wanted,
            downloadedURLs: downloadedURLs,
            failedCount: failedCount
        )
        progress?.yield(.completed(fileCount: downloadedURLs.count))
        return downloadedURLs
    }

    // MARK: - Directory listing (read-only, no download or archive)

    /// Download the root directory and return all entries matching `fileType`.
    /// Does NOT archive files or send SYNC_COMPLETE — safe for read-only presence checks.
    func listFiles(ofType fileType: FileType) async throws -> [FileEntry] {
        let entries = try await downloadDirectory(progress: nil)
        return entries.compactMap { entry in
            guard let ft = entry.fitFileType, ft == fileType else { return nil }
            return FileEntry(index: entry.fileIndex, fileType: ft, size: entry.fileSize, date: entry.date)
        }
    }

    // MARK: - Filter handshake (watch-initiated path only)

    private func sendFilterAndWait() async throws {
        BLELogger.sync.debug("Sync: sending FilterMessage")
        let statusMsg = try await client.sendAndWait(
            FilterMessage().toMessage(),
            awaitType: .directoryFilter,
            timeout: .seconds(10)
        )
        // Status frame is a compact-typed RESPONSE for 5007 — just check it arrived.
        BLELogger.sync.debug("Sync: FilterStatus received (payload \(statusMsg.payload.count) bytes)")
    }

    // MARK: - Directory download

    private func downloadDirectory(
        progress: AsyncStream<SyncProgress>.Continuation?
    ) async throws -> [DirectoryEntry] {
        BLELogger.sync.debug("Sync: requesting root directory (fileIndex=0)")

        let rawBody = try await downloadData(
            fileIndex: 0,
            label: "directory",
            progress: progress
        )

        let entries = try DirectoryEntry.parseAll(from: rawBody)
        BLELogger.sync.info("Sync: directory has \(entries.count) entries (\(rawBody.count) bytes)")

        for entry in entries {
            let typeStr = entry.fitFileType.map(String.init(describing:)) ?? "unknown(\(entry.fileDataType)/\(entry.fileSubType))"
            let archivedStr = entry.isArchived ? " [archived]" : ""
            BLELogger.sync.info(
                "Sync:   entry fileIndex=\(entry.fileIndex) type=\(typeStr) size=\(entry.fileSize)B date=\(entry.date)\(archivedStr)"
            )
        }

        return entries
    }

    // MARK: - Individual file download

    private func downloadFile(
        entry: DirectoryEntry,
        progress: AsyncStream<SyncProgress>.Continuation?
    ) async throws -> URL {
        let label = "file[\(entry.fileIndex)] \(entry.fitFileType.map(String.init(describing:)) ?? "unknown") \(entry.fileSize)B"
        BLELogger.sync.info("Sync: downloading \(label)")

        let rawData = try await downloadData(
            fileIndex: entry.fileIndex,
            label: label,
            progress: progress
        )

        guard !rawData.isEmpty else {
            throw SyncError.downloadFailed(fileIndex: entry.fileIndex, reason: "0 bytes received")
        }

        let url = try saveFITFile(rawData, entry: entry)
        BLELogger.sync.info("Sync: saved \(label) → \(url.lastPathComponent)")
        return url
    }

    // MARK: - Core chunk-download loop (shared by directory and file downloads)

    /// Send a `DownloadRequest` for `fileIndex`, receive all chunks, return the
    /// reassembled bytes.
    ///
    /// The subscription is unsubscribed synchronously (within the same actor hop) before
    /// this method returns, so the next caller's `subscribe` cannot race against a deferred
    /// cleanup task.
    private func downloadData(
        fileIndex: UInt16,
        label: String,
        progress: AsyncStream<SyncProgress>.Continuation?
    ) async throws -> Data {

        // Register the chunk subscription BEFORE sending the request — no TOCTOU window.
        let chunkStream = await client.subscribe(to: .fileTransferData)

        // All work is inside a do/catch so we can unsubscribe synchronously on both
        // the success and error paths.  Using `defer { Task { ... } }` here is WRONG:
        // the async Task races against the next file's subscribe call.
        var buffer = Data()
        do {
            // The Instinct Solar sends DownloadRequestStatus as a full RESPONSE(0x1388),
            // not as a compact-typed frame decoding to 0x138A (.downloadRequest).
            let statusMsg = try await client.sendAndWait(
                DownloadRequestMessage(fileIndex: fileIndex).toMessage(),
                awaitType: .response,
                timeout: .seconds(10)
            )

            let status = try DownloadRequestStatus.decode(from: statusMsg)
            BLELogger.sync.info(
                "Sync: \(label) — DownloadRequestStatus outerStatus=\(status.status) downloadStatus=\(status.downloadStatus) maxFileSize=\(status.maxFileSize)"
            )
            // Only gate on the outer ACK; some firmware returns non-zero downloadStatus
            // even when proceeding (observed: status=3, maxFileSize=0 on Instinct Solar).
            guard status.status == 0 else {
                throw SyncError.downloadFailed(
                    fileIndex: fileIndex,
                    reason: "DownloadRequestStatus NACK: outerStatus=\(status.status) downloadStatus=\(status.downloadStatus)"
                )
            }

            // maxFileSize=0 → size unknown; rely on last-chunk flag (bit 0x08) to break.
            let expectedSize = Int(status.maxFileSize)
            BLELogger.sync.info("Sync: \(label) — downloading \(expectedSize == 0 ? "unknown" : "\(expectedSize)")B")
            buffer.reserveCapacity(expectedSize)
            var runningCRC: UInt16 = 0
            var chunkIndex = 0

            for await chunkMsg in chunkStream {
                let chunk = try FileTransferDataMessage.decode(from: chunkMsg)

                guard chunk.dataOffset == buffer.count else {
                    BLELogger.sync.error(
                        "Sync: \(label) chunk #\(chunkIndex) offset mismatch expected=\(buffer.count) got=\(chunk.dataOffset)"
                    )
                    throw SyncError.offsetMismatch(
                        expected: UInt32(buffer.count),
                        received: chunk.dataOffset
                    )
                }

                let computedCRC = CRC16.compute(data: chunk.data, seed: runningCRC)
                guard computedCRC == chunk.chunkCRC else {
                    BLELogger.sync.error(
                        "Sync: \(label) chunk #\(chunkIndex) CRC mismatch expected=0x\(String(format: "%04X", chunk.chunkCRC)) computed=0x\(String(format: "%04X", computedCRC))"
                    )
                    throw SyncError.crcMismatch(expected: chunk.chunkCRC, computed: computedCRC)
                }
                runningCRC = computedCRC
                buffer.append(chunk.data)
                chunkIndex += 1

                BLELogger.sync.debug(
                    "Sync: \(label) chunk #\(chunkIndex) offset=\(chunk.dataOffset) size=\(chunk.data.count)B flags=0x\(String(format: "%02X", chunk.flags)) crc=0x\(String(format: "%04X", runningCRC)) progress=\(buffer.count)/\(expectedSize == 0 ? "?" : "\(expectedSize)")"
                )

                try await client.send(message: FileTransferDataACK(nextDataOffset: UInt32(buffer.count)).toMessage())

                progress?.yield(.downloading(
                    file: label,
                    bytesReceived: buffer.count,
                    totalBytes: expectedSize > 0 ? expectedSize : nil
                ))

                let isLastChunk = (chunk.flags & 0x08) != 0
                if expectedSize > 0 && buffer.count >= expectedSize { break }
                if isLastChunk {
                    BLELogger.sync.debug("Sync: \(label) last-chunk flag set — transfer complete")
                    break
                }
            }

            guard expectedSize == 0 || buffer.count == expectedSize else {
                BLELogger.sync.error(
                    "Sync: \(label) stream ended prematurely: \(buffer.count)/\(expectedSize) bytes after \(chunkIndex) chunk(s)"
                )
                throw SyncError.downloadFailed(
                    fileIndex: fileIndex,
                    reason: "Stream ended with \(buffer.count)/\(expectedSize) bytes"
                )
            }

            BLELogger.sync.info("Sync: \(label) — complete (\(chunkIndex) chunks, \(buffer.count)B, finalCRC=0x\(String(format: "%04X", runningCRC)))")

        } catch {
            // Tell the watch to stop transmitting so its chunks don't bleed into
            // the next file's subscription.
            let abortAck = FileTransferDataACK(transferStatus: .abort, nextDataOffset: UInt32(buffer.count))
            try? await client.send(message: abortAck.toMessage())
            // Unsubscribe synchronously before rethrowing — no async Task race.
            await client.unsubscribe(from: .fileTransferData)
            throw error
        }

        // Success path: unsubscribe synchronously before returning.
        await client.unsubscribe(from: .fileTransferData)
        return buffer
    }

    // MARK: - Archive flag

    private func archiveFile(entry: DirectoryEntry) async throws {
        let flagMsg = SetFileFlagsMessage(fileIndex: entry.fileIndex).toMessage()
        // Brief timeout — watch may not ACK promptly; ignore the error if it times out.
        // Like DownloadRequestStatus, the ACK arrives as a full RESPONSE(0x1388), not compact-typed.
        _ = try? await client.sendAndWait(flagMsg, awaitType: .response, timeout: .seconds(5))
        BLELogger.sync.debug("Sync: archived fileIndex=\(entry.fileIndex)")
    }

    // MARK: - Sync summary

    private func logSyncSummary(
        allEntries: [DirectoryEntry],
        wanted: [DirectoryEntry],
        downloadedURLs: [URL],
        failedCount: Int
    ) {
        let archived   = allEntries.filter(\.isArchived).count
        let unknown    = allEntries.filter { !$0.isArchived && $0.fitFileType == nil }.count
        let notWanted  = allEntries.count - archived - unknown - wanted.count

        // Per-type breakdown of what was successfully saved.
        var byType: [String: (files: Int, bytes: Int)] = [:]
        for url in downloadedURLs {
            let name = url.deletingPathExtension().lastPathComponent
            let typeName = name.components(separatedBy: "_").first ?? "unknown"
            let bytes = (try? Data(contentsOf: url).count) ?? 0
            let cur = byType[typeName] ?? (files: 0, bytes: 0)
            byType[typeName] = (files: cur.files + 1, bytes: cur.bytes + bytes)
        }

        var lines: [String] = ["─── Sync complete ───"]
        lines.append("  directory : \(allEntries.count) entries")
        lines.append("  requested : \(wanted.count)  |  saved: \(downloadedURLs.count)  |  failed: \(failedCount)")
        lines.append("  skipped   : \(archived) already-archived, \(unknown) unknown type, \(notWanted) not in sync set")
        if !byType.isEmpty {
            lines.append("  by type:")
            for (typeName, stat) in byType.sorted(by: { $0.key < $1.key }) {
                lines.append("    \(typeName): \(stat.files) file(s), \(stat.bytes)B")
            }
        }
        lines.append("─────────────────────")
        BLELogger.sync.info("\(lines.joined(separator: "\n"))")
    }

    // MARK: - Temp-file storage

    private func saveFITFile(_ data: Data, entry: DirectoryEntry) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("compass-sync", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let dateStr = formatter.string(from: entry.date)
            .replacingOccurrences(of: ":", with: "-")

        let typeName = entry.fitFileType.map(String.init(describing:)) ?? "unknown"
        let filename = "\(typeName)_\(dateStr)_\(entry.fileIndex).fit"
        let url = dir.appendingPathComponent(filename)

        try data.write(to: url)
        return url
    }
}
