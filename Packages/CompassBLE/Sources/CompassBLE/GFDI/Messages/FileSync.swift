import Foundation

// MARK: - SynchronizationMessage (5037, watch → phone)

/// Watch-initiated sync trigger.  The watch sends this when it has fresh data
/// and wants the phone to fetch it.
///
/// Wire format (payload):
/// ```
/// [type: UInt8]           SynchronizationType (0/1/2; semantics unknown, ignored)
/// [bitmaskSize: UInt8]    4 or 8
/// [bitmask: bitmaskSize bytes LE]   one bit per FileType ordinal
/// ```
///
/// Reference: Gadgetbridge `SynchronizationMessage.java:22–42`.
public struct SynchronizationMessage: Sendable {

    /// Bit positions that indicate the watch has relevant data.
    /// Gadgetbridge `shouldProceed()` checks any of these bits.
    private static let workoutsBit: Int = 3
    private static let activitiesBit: Int = 5
    private static let activitySummaryBit: Int = 21
    private static let sleepBit: Int = 26

    public let syncType: UInt8
    public let bitmask: UInt64

    /// `true` if the bitmask contains at least one data type we care about.
    public var shouldProceed: Bool {
        let relevant: [Int] = [
            SynchronizationMessage.workoutsBit,
            SynchronizationMessage.activitiesBit,
            SynchronizationMessage.activitySummaryBit,
            SynchronizationMessage.sleepBit,
        ]
        return relevant.contains { (bitmask >> $0) & 1 == 1 }
    }

    public static func decode(from payload: Data) throws -> SynchronizationMessage {
        var reader = ByteReader(data: payload)
        let syncType = try reader.readUInt8()
        let bitmaskSize = Int(try reader.readUInt8())
        guard bitmaskSize == 4 || bitmaskSize == 8 else {
            throw SyncError.malformedMessage("SynchronizationMessage: unexpected bitmaskSize \(bitmaskSize)")
        }
        var bitmask: UInt64 = 0
        for i in 0..<bitmaskSize {
            bitmask |= UInt64(try reader.readUInt8()) << (i * 8)
        }
        return SynchronizationMessage(syncType: syncType, bitmask: bitmask)
    }
}

// MARK: - FilterMessage (5007, phone → watch)

/// Sent by the phone to acknowledge a `SynchronizationMessage` and consent to sync.
/// The one-byte payload is always `3` (UNK_3); semantics are unknown but Gadgetbridge
/// always uses this value.
///
/// Reference: Gadgetbridge `FilterMessage.java:11–18`.
public struct FilterMessage: Sendable {
    public init() {}

    public func toMessage() -> GFDIMessage {
        GFDIMessage(type: .directoryFilter, payload: Data([0x03]))
    }
}

// MARK: - DownloadRequestMessage (5002, phone → watch)

/// Ask the watch to begin streaming a file.  `fileIndex = 0` requests the root
/// directory; any other value requests a specific file from the directory listing.
///
/// Wire format (payload, all LE):
/// ```
/// [fileIndex: UInt16]
/// [dataOffset: UInt32]    0 for a NEW request
/// [requestType: UInt8]    0=CONTINUE, 1=NEW
/// [crcSeed: UInt16]       0 for a NEW request
/// [dataSize: UInt32]      0 = "send everything"
/// ```
///
/// Gadgetbridge always sends NEW; resume (CONTINUE) is not implemented here.
///
/// Reference: Gadgetbridge `DownloadRequestMessage.java:27–37`.
public struct DownloadRequestMessage: Sendable {

    public let fileIndex: UInt16

    public init(fileIndex: UInt16) {
        self.fileIndex = fileIndex
    }

    public func toMessage() -> GFDIMessage {
        var payload = Data()
        payload.appendUInt16LE(fileIndex)
        payload.appendUInt32LE(0)   // dataOffset = 0
        payload.append(0x01)        // requestType = NEW
        payload.appendUInt16LE(0)   // crcSeed = 0
        payload.appendUInt32LE(0)   // dataSize = 0 (send everything)
        return GFDIMessage(type: .downloadRequest, payload: payload)
    }
}

// MARK: - DownloadRequestStatus (decoded from compact-typed response to 5002)

/// The watch's reply to a `DownloadRequestMessage`.  Arrives as a compact-typed
/// frame that decodes to message type 5002 (`.downloadRequest`).
///
/// Wire format (payload after the 3-byte RESPONSE header):
/// ```
/// [status: UInt8]          0 = ACK
/// [downloadStatus: UInt8]  0=OK, 1=INDEX_UNKNOWN, 2=INDEX_NOT_READABLE,
///                          3=NO_SPACE_LEFT, 4=INVALID, 5=NOT_READY, 6=CRC_INCORRECT
/// [maxFileSize: UInt32 LE] total bytes the watch is about to push
/// ```
///
/// Reference: Gadgetbridge `DownloadRequestStatusMessage.java:15–29`.
public struct DownloadRequestStatus: Sendable {

    public enum DownloadStatus: UInt8, Sendable {
        case ok = 0
        case indexUnknown = 1
        case indexNotReadable = 2
        case noSpaceLeft = 3
        case invalid = 4
        case notReady = 5
        case crcIncorrect = 6
        case unknown = 255
    }

    public let status: UInt8
    public let downloadStatus: DownloadStatus
    public let maxFileSize: UInt32

    public var canProceed: Bool {
        status == 0 && downloadStatus == .ok
    }

    /// Decode from the payload of an incoming RESPONSE (5000) message whose
    /// `originalType` is `downloadRequest` (5002).
    ///
    /// The RESPONSE payload starts with [originalType: UInt16][status: UInt8].
    /// The download-specific fields follow that 3-byte header.
    public static func decode(from msg: GFDIMessage) throws -> DownloadRequestStatus {
        var reader = ByteReader(data: msg.payload)
        // Skip the 3-byte RESPONSE header (originalType UInt16 + outer status UInt8)
        _ = try reader.readUInt16LE()   // originalType (5002)
        let outerStatus = try reader.readUInt8()
        let rawDownloadStatus = try reader.readUInt8()
        let maxFileSize = try reader.readUInt32LE()
        let downloadStatus = DownloadStatus(rawValue: rawDownloadStatus) ?? .unknown
        return DownloadRequestStatus(
            status: outerStatus,
            downloadStatus: downloadStatus,
            maxFileSize: maxFileSize
        )
    }
}

// MARK: - FileTransferDataMessage (5004, watch → phone)

/// One chunk of file data streamed from the watch during a download.
///
/// Wire format (payload):
/// ```
/// [flags: UInt8]           always 0 in Gadgetbridge
/// [chunkCRC: UInt16 LE]    running CRC of all bytes received so far (including this chunk)
/// [dataOffset: UInt32 LE]  absolute byte offset of this chunk in the file
/// [payload: remaining bytes]
/// ```
///
/// Important: `chunkCRC` is the cumulative CRC since byte 0, not just this chunk.
/// Verify using `CRC16.compute(data: chunk.data, seed: previousRunningCRC)`.
///
/// Reference: Gadgetbridge `FileTransferDataMessage.java:31–39, 53–63`.
public struct FileTransferDataMessage: Sendable {

    public let flags: UInt8
    public let chunkCRC: UInt16
    public let dataOffset: UInt32
    public let data: Data

    public static func decode(from msg: GFDIMessage) throws -> FileTransferDataMessage {
        var reader = ByteReader(data: msg.payload)
        let flags = try reader.readUInt8()
        let chunkCRC = try reader.readUInt16LE()
        let dataOffset = try reader.readUInt32LE()
        let remaining = reader.remaining
        let data = remaining > 0 ? (try reader.readBytes(remaining)) : Data()
        return FileTransferDataMessage(flags: flags, chunkCRC: chunkCRC, dataOffset: dataOffset, data: data)
    }
}

// MARK: - FileTransferDataACK (phone → watch, per-chunk)

/// Per-chunk acknowledgement sent immediately after each `FileTransferDataMessage`.
///
/// Encoded as a full RESPONSE (5000) frame — not compact-typed — matching
/// Gadgetbridge `FileTransferDataStatusMessage.generateOutgoing`.
///
/// Wire format (RESPONSE payload):
/// ```
/// [originalType: UInt16 LE = 5004]
/// [outerStatus: UInt8 = 0 ACK]
/// [transferStatus: UInt8]  0=OK, 1=RESEND, 2=ABORT, 3=CRC_MISMATCH,
///                          4=OFFSET_MISMATCH, 5=SYNC_PAUSED
/// [nextDataOffset: UInt32 LE]  first byte the phone expects next (= offset + chunkLen)
/// ```
///
/// The `nextDataOffset` field is how the watch knows where to resume; it must
/// equal `dataOffset + chunk.data.count` of the just-received chunk.
///
/// Reference: Gadgetbridge `FileTransferDataStatusMessage.java:48–58`.
public struct FileTransferDataACK: Sendable {

    public enum TransferStatus: UInt8, Sendable {
        case ok = 0
        case resend = 1
        case abort = 2
        case crcMismatch = 3
        case offsetMismatch = 4
        case syncPaused = 5
    }

    public let transferStatus: TransferStatus
    public let nextDataOffset: UInt32

    public init(transferStatus: TransferStatus = .ok, nextDataOffset: UInt32) {
        self.transferStatus = transferStatus
        self.nextDataOffset = nextDataOffset
    }

    public func toMessage() -> GFDIMessage {
        var extra = Data()
        extra.append(transferStatus.rawValue)
        extra.appendUInt32LE(nextDataOffset)
        return GFDIResponse(
            originalType: .fileTransferData,
            status: .ack,
            additionalPayload: extra
        ).toMessage()
    }
}

// MARK: - SetFileFlagsMessage (5008, phone → watch)

/// Mark a file with the ARCHIVE flag after successful download, so the watch
/// removes it from the sync queue.  The watch clears the file on its next sweep.
///
/// Wire format (payload):
/// ```
/// [fileIndex: UInt16 LE]
/// [flags: UInt8]    bit 4 (0x10) = ARCHIVE
/// ```
///
/// Reference: Gadgetbridge `SetFileFlagsMessage.java:18–26`.
public struct SetFileFlagsMessage: Sendable {

    public static let archiveFlag: UInt8 = 0x10

    public let fileIndex: UInt16
    public let flags: UInt8

    public init(fileIndex: UInt16, flags: UInt8 = SetFileFlagsMessage.archiveFlag) {
        self.fileIndex = fileIndex
        self.flags = flags
    }

    public func toMessage() -> GFDIMessage {
        var payload = Data()
        payload.appendUInt16LE(fileIndex)
        payload.append(flags)
        return GFDIMessage(type: .setFileFlag, payload: payload)
    }
}

// MARK: - DirectoryEntry (16 bytes, parsed from root-directory download body)

/// One row in the Garmin device's root directory.  The directory file is itself
/// a concatenation of these 16-byte records.
///
/// Wire format (all LE):
/// ```
/// offset  size  field
///  0       2    fileIndex       index to pass to DownloadRequestMessage
///  2       1    fileDataType    128 = FIT, 255 = other, 8 = DEVICE_XML
///  3       1    fileSubType     FIT sub-type (see FileType enum)
///  4       2    fileNumber      type-specific; opaque
///  6       1    specificFlags   type-specific; opaque
///  7       1    fileFlags       bit 4 (0x10) = ARCHIVE (already synced)
///  8       4    fileSize        total bytes
/// 12       4    fileTimestamp   Garmin-epoch seconds (add 631065600 for Unix)
/// ```
///
/// Reference: Gadgetbridge `FileTransferHandler.java:214–256`.
public struct DirectoryEntry: Sendable {

    public static let rowSize = 16

    public let fileIndex: UInt16
    public let fileDataType: UInt8
    public let fileSubType: UInt8
    public let fileNumber: UInt16
    public let specificFlags: UInt8
    public let fileFlags: UInt8
    public let fileSize: UInt32
    public let fileTimestamp: UInt32

    /// `true` if the file has already been archived (synced) and should be skipped.
    public var isArchived: Bool { fileFlags & SetFileFlagsMessage.archiveFlag != 0 }

    /// The decoded FIT file type, or `nil` for non-FIT or unknown-subtype files.
    public var fitFileType: FileType? {
        FileType(dataType: fileDataType, subType: fileSubType)
    }

    /// Garmin-epoch timestamp converted to `Date`.
    public var date: Date {
        FileEntry.dateFromGarminEpoch(fileTimestamp)
    }

    /// Parse all 16-byte directory entries from the raw directory body.
    ///
    /// - Throws: `SyncError.malformedMessage` if the buffer length is not a
    ///   multiple of 16 bytes.
    public static func parseAll(from data: Data) throws -> [DirectoryEntry] {
        guard data.count % rowSize == 0 else {
            throw SyncError.malformedMessage(
                "Directory body length \(data.count) is not a multiple of \(rowSize)"
            )
        }
        var entries: [DirectoryEntry] = []
        var reader = ByteReader(data: data)
        while !reader.isAtEnd {
            let fileIndex    = try reader.readUInt16LE()
            let dataType     = try reader.readUInt8()
            let subType      = try reader.readUInt8()
            let fileNumber   = try reader.readUInt16LE()
            let specFlags    = try reader.readUInt8()
            let fileFlags    = try reader.readUInt8()
            let fileSize     = try reader.readUInt32LE()
            let timestamp    = try reader.readUInt32LE()

            // Gadgetbridge skips all-zero rows to avoid infinite-loop edge cases.
            if fileIndex == 0 && dataType == 0 && fileSize == 0 { continue }

            entries.append(DirectoryEntry(
                fileIndex:     fileIndex,
                fileDataType:  dataType,
                fileSubType:   subType,
                fileNumber:    fileNumber,
                specificFlags: specFlags,
                fileFlags:     fileFlags,
                fileSize:      fileSize,
                fileTimestamp: timestamp
            ))
        }
        return entries
    }
}

// MARK: - SyncError

/// Errors specific to the file sync FSM.
public enum SyncError: Error, Sendable {
    case notConnected
    case syncAlreadyInProgress
    case directoryDownloadFailed(String)
    case malformedMessage(String)
    case crcMismatch(expected: UInt16, computed: UInt16)
    case offsetMismatch(expected: UInt32, received: UInt32)
    case downloadFailed(fileIndex: UInt16, reason: String)
    case timeout
    /// No chunk arrived within the per-chunk deadline (BLE suspended or watch out of range).
    case chunkTimeout
    /// The chunk stream closed before the last-chunk flag was received.
    case streamEnded
}
