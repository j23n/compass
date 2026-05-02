import Foundation
import os
import Security

/// Uploads a file to the watch via the GFDI protocol (phone → watch).
///
/// Protocol summary:
/// ```
/// phone → CreateFile (5005, size, nonce)
/// watch → RESPONSE(5000) with CreateFileStatus (assigned fileIndex)
///
/// phone → UploadRequest (5003, fileIndex, size)
/// watch → RESPONSE(5000) with UploadRequestStatus (maxPacketSize)
///
/// phone subscribes to .response for chunk ACKs
/// for each chunk:
///   phone → FileTransferDataChunk (5004, offset, CRC, data)
///   watch → RESPONSE(5000) with ACK (originalType=5004, nextOffset)
///   [unrelated RESPONSE messages skipped by filtering on originalType]
/// phone unsubscribes from .response
///
/// phone → SystemEvent(SYNC_COMPLETE)
/// ```
///
/// NOTE: sendAndWait(.response) is NOT used for chunks because any unrelated
/// RESPONSE the watch sends during the (slow) BLE writes resolves the one-shot
/// continuation before the real ACK arrives.  A persistent subscription with
/// originalType filtering handles this correctly.
///
/// Reference: course-upload.md § BLE Upload Protocol
actor FileUploadSession {

    private let client: GFDIClient
    private let maxPacketSize: Int

    init(client: GFDIClient, maxPacketSize: Int = 375) {
        self.client = client
        self.maxPacketSize = maxPacketSize
    }

    // MARK: - Upload entry point

    /// Upload a file to the watch.
    /// - Returns: The file index the watch assigned (store this for later presence checks).
    func upload(
        data: Data,
        progress: AsyncStream<SyncProgress>.Continuation?
    ) async throws -> UInt16 {
        BLELogger.sync.info("Upload: starting (\(data.count) bytes)")
        progress?.yield(.starting)

        // Step 1: CreateFile handshake
        let createMsg = CreateFileMessage(fileSize: UInt32(data.count))
        let createResp = try await client.sendAndWait(
            createMsg.toMessage(),
            awaitType: .response,
            timeout: .seconds(10)
        )
        let createStatus = try CreateFileStatus.decode(from: createResp)
        BLELogger.sync.info(
            "Upload: CreateFileStatus createStatus=\(createStatus.createStatus) fileIndex=\(createStatus.fileIndex)"
        )
        guard createStatus.canProceed else {
            throw SyncError.downloadFailed(
                fileIndex: 0,
                reason: "CreateFile failed: \(createStatus.createStatus)"
            )
        }

        let fileIndex = createStatus.fileIndex

        // Step 2: UploadRequest
        let uploadMsg = UploadRequestMessage(fileIndex: fileIndex, dataSize: UInt32(data.count))
        let uploadResp = try await client.sendAndWait(
            uploadMsg.toMessage(),
            awaitType: .response,
            timeout: .seconds(10)
        )
        let uploadStatus = try UploadRequestStatus.decode(from: uploadResp)
        BLELogger.sync.info(
            "Upload: UploadRequestStatus maxFileSize=\(uploadStatus.maxFileSize) (chunkSize from ML=\(self.maxPacketSize))"
        )
        guard uploadStatus.canProceed else {
            throw SyncError.downloadFailed(
                fileIndex: fileIndex,
                reason: "UploadRequest failed: \(uploadStatus.uploadStatus)"
            )
        }
        guard UInt32(data.count) <= uploadStatus.maxFileSize else {
            throw SyncError.downloadFailed(
                fileIndex: fileIndex,
                reason: "File too large for slot: \(data.count) > \(uploadStatus.maxFileSize)"
            )
        }

        // Chunk size is the ML-negotiated maxPacketSize (NOT the response's
        // maxFileSize, which is the slot's total file capacity). 13 = GFDI
        // overhead per FileTransferData frame (size 2 + type 2 + flags 1 +
        // chunkCRC 2 + offset 4 + frame CRC 2).
        let effectiveChunkSize = self.maxPacketSize - 13
        let fileTransferDataType = GFDIMessageType.fileTransferData.rawValue

        // Step 3: Subscribe to .response BEFORE sending any chunks.
        // The subscription buffers messages so an ACK that arrives during BLE writes
        // is not lost, and we can filter out unrelated RESPONSE messages by originalType.
        let ackStream = await client.subscribe(to: .response)

        var offset: UInt32 = 0
        var runningCRC: UInt16 = 0
        var chunkIndex = 0

        do {
            while offset < data.count {
                let chunkEnd = min(offset + UInt32(effectiveChunkSize), UInt32(data.count))
                let chunkData = data[Int(offset)..<Int(chunkEnd)]
                let isLast = chunkEnd >= UInt32(data.count)

                runningCRC = FITCRC.compute(Data(chunkData), seed: runningCRC)

                let chunk = FileTransferDataChunk(
                    flags: isLast ? .last : .middle,
                    dataOffset: offset,
                    chunkCRC: runningCRC,
                    data: Data(chunkData)
                )

                try await client.send(message: chunk.toMessage())
                BLELogger.sync.debug(
                    "Upload: sent chunk #\(chunkIndex) offset=\(offset) size=\(chunkData.count) flags=0x\(String(format: "%02X", chunk.flags.rawValue))"
                )

                // Wait for the per-chunk ACK from the watch, ignoring any unrelated RESPONSE
                // messages that arrive during the slow BLE writes (e.g., delayed responses
                // from earlier operations or watch-initiated protocol messages).
                let idx = chunkIndex  // immutable snapshot for @Sendable capture
                let ack = try await withThrowingTaskGroup(of: FileTransferDataUploadACK.self) { group in
                    group.addTask {
                        for await responseMsg in ackStream {
                            let p = responseMsg.payload
                            guard p.count >= 2,
                                  UInt16(p[p.startIndex]) | (UInt16(p[p.startIndex + 1]) << 8)
                                      == fileTransferDataType else {
                                BLELogger.sync.debug("Upload: skipping unrelated RESPONSE during chunk \(idx)")
                                continue
                            }
                            return try FileTransferDataUploadACK.decode(from: responseMsg)
                        }
                        throw SyncError.timeout
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(15))
                        throw SyncError.timeout
                    }
                    guard let result = try await group.next() else { throw SyncError.timeout }
                    group.cancelAll()
                    return result
                }

                guard ack.isOK else {
                    throw SyncError.downloadFailed(fileIndex: fileIndex, reason: "Chunk \(chunkIndex) NACK: \(ack.transferStatus)")
                }

                BLELogger.sync.debug("Upload: ACK chunk #\(chunkIndex) nextOffset=\(ack.nextDataOffset)")
                offset = ack.nextDataOffset
                chunkIndex += 1

                progress?.yield(.downloading(
                    file: "course.fit",
                    bytesReceived: Int(offset),
                    totalBytes: data.count
                ))

                if isLast { break }
            }

            BLELogger.sync.info(
                "Upload: complete (\(chunkIndex) chunks, \(data.count)B, finalCRC=0x\(String(format: "%04X", runningCRC)))"
            )

        } catch {
            let abortChunk = FileTransferDataChunk(
                flags: .abort,
                dataOffset: offset,
                chunkCRC: runningCRC,
                data: Data()
            )
            try? await client.send(message: abortChunk.toMessage())
            await client.unsubscribe(from: .response)
            throw error
        }

        await client.unsubscribe(from: .response)
        try? await client.send(message: SystemEventMessage(eventType: .syncComplete).toMessage())
        progress?.yield(.completed(fileCount: 1))
        return fileIndex
    }
}

// MARK: - FITCRC

/// CRC-16 used by the FIT file format.
enum FITCRC {
    private static let table: [UInt16] = {
        var t = [UInt16](repeating: 0, count: 16)
        t[0]  = 0x0000; t[1]  = 0xCC01; t[2]  = 0xD801; t[3]  = 0x1400
        t[4]  = 0xF001; t[5]  = 0x3C00; t[6]  = 0x2800; t[7]  = 0xE401
        t[8]  = 0xA001; t[9]  = 0x6C00; t[10] = 0x7800; t[11] = 0xB401
        t[12] = 0x5000; t[13] = 0x9C01; t[14] = 0x8801; t[15] = 0x4400
        return t
    }()

    static func compute(_ data: Data, seed: UInt16 = 0) -> UInt16 {
        var crc = seed
        for byte in data {
            var tmp = table[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ table[Int(byte & 0xF)]
            tmp = table[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ table[Int((byte >> 4) & 0xF)]
        }
        return crc
    }
}
