import Foundation

// MARK: - CreateFileMessage (5005, phone → watch)

/// Initiate a file upload to the watch.
///
/// Wire format (payload, all LE):
/// ```
/// [fileSize: UInt32]
/// [fileDataType: UInt8]       128 (FILE_COURSES)
/// [fileSubType: UInt8]        6 (COURSE)
/// [fileIndex: UInt16]         0 (let watch assign)
/// [reserved: UInt8]           0
/// [subtypeMask: UInt8]        0
/// [numberMask: UInt16]        0xFFFF
/// [unknown: UInt16]           0
/// [nonce: 8 bytes]            Random, must be non-zero
/// ```
///
/// Total payload: 22 bytes.
public struct CreateFileMessage: Sendable {
    public let fileSize: UInt32
    public let fileDataType: UInt8 = 128
    public let fileSubType: UInt8 = 6
    public let nonce: Data

    public init(fileSize: UInt32, nonce: Data? = nil) {
        self.fileSize = fileSize
        if let nonce = nonce {
            self.nonce = nonce
        } else {
            var bytes = [UInt8](repeating: 0, count: 8)
            _ = SecRandomCopyBytes(kSecRandomDefault, 8, &bytes)
            self.nonce = Data(bytes)
        }
    }

    public func toMessage() -> GFDIMessage {
        var payload = Data()
        payload.appendUInt32LE(fileSize)
        payload.append(fileDataType)
        payload.append(fileSubType)
        payload.appendUInt16LE(0)        // fileIndex = 0
        payload.append(0)                // reserved
        payload.append(0)                // subtypeMask
        payload.appendUInt16LE(0xFFFF)   // numberMask
        payload.appendUInt16LE(0)        // unknown
        payload.append(nonce)
        return GFDIMessage(type: .createFile, payload: payload)
    }
}

// MARK: - CreateFileStatus (decoded from RESPONSE to 5005)

/// The watch's reply to a CreateFileMessage, wrapped in a RESPONSE(5000) frame.
///
/// Wire format (payload after RESPONSE header):
/// ```
/// [status: UInt8]        0 = success
/// [createStatus: UInt8]  0=OK, 1=DUPLICATE, 2=NO_SPACE, 3=UNSUPPORTED, 4=NO_SLOTS
/// [fileIndex: UInt16 LE] assigned index for subsequent operations
/// [fileDataType: UInt8]  echo of request (128)
/// [fileSubType: UInt8]   echo of request (6)
/// [fileNumber: UInt16 LE]
/// ```
public struct CreateFileStatus: Sendable {
    public enum Status: UInt8, Sendable {
        case ok = 0
        case duplicate = 1
        case noSpace = 2
        case unsupported = 3
        case noSlots = 4
        case unknown = 255
    }

    public let status: UInt8
    public let createStatus: Status
    public let fileIndex: UInt16
    public let fileDataType: UInt8
    public let fileSubType: UInt8
    public let fileNumber: UInt16

    public var canProceed: Bool {
        status == 0 && createStatus == .ok
    }

    /// Decode from a RESPONSE(5000) message whose originalType is createFile(5005).
    public static func decode(from msg: GFDIMessage) throws -> CreateFileStatus {
        var reader = ByteReader(data: msg.payload)
        _ = try reader.readUInt16LE()   // originalType (5005)
        let outerStatus = try reader.readUInt8()
        let rawCreateStatus = try reader.readUInt8()
        let fileIndex = try reader.readUInt16LE()
        let fileDataType = try reader.readUInt8()
        let fileSubType = try reader.readUInt8()
        let fileNumber = try reader.readUInt16LE()
        let createStatus = Status(rawValue: rawCreateStatus) ?? .unknown
        return CreateFileStatus(
            status: outerStatus,
            createStatus: createStatus,
            fileIndex: fileIndex,
            fileDataType: fileDataType,
            fileSubType: fileSubType,
            fileNumber: fileNumber
        )
    }
}

// MARK: - UploadRequestMessage (5003, phone → watch)

/// Request to begin uploading a previously-created file.
///
/// Wire format (payload, all LE):
/// ```
/// [fileIndex: UInt16]    from CreateFileStatus
/// [dataSize: UInt32]     total bytes to upload
/// [dataOffset: UInt32]   0 (always start from beginning)
/// [crcSeed: UInt16]      0 (initialize CRC with this seed)
/// ```
///
/// Total payload: 12 bytes.
public struct UploadRequestMessage: Sendable {
    public let fileIndex: UInt16
    public let dataSize: UInt32
    public let dataOffset: UInt32 = 0
    public let crcSeed: UInt16 = 0

    public init(fileIndex: UInt16, dataSize: UInt32) {
        self.fileIndex = fileIndex
        self.dataSize = dataSize
    }

    public func toMessage() -> GFDIMessage {
        var payload = Data()
        payload.appendUInt16LE(fileIndex)
        payload.appendUInt32LE(dataSize)
        payload.appendUInt32LE(dataOffset)
        payload.appendUInt16LE(crcSeed)
        return GFDIMessage(type: .uploadRequest, payload: payload)
    }
}

// MARK: - UploadRequestStatus (decoded from RESPONSE to 5003)

/// The watch's reply to an UploadRequestMessage, wrapped in RESPONSE(5000).
///
/// Wire format (payload after RESPONSE header), per Gadgetbridge
/// `messages/status/UploadRequestStatusMessage.java:19–48`:
/// ```
/// [status: UInt8]            0 = success
/// [uploadStatus: UInt8]      0=OK, 1=INDEX_UNKNOWN, 2=INDEX_NOT_WRITEABLE,
///                            3=NO_SPACE, 4=INVALID, 5=NOT_READY, 6=CRC_INCORRECT
/// [dataOffset: UInt32 LE]    next byte the watch expects (must equal 0 for fresh upload)
/// [maxFileSize: UInt32 LE]   max total file size for this slot — NOT the per-chunk size
/// [crcSeed: UInt16 LE]       CRC seed echo
/// ```
///
/// IMPORTANT: The 4-byte field after `dataOffset` is the **slot's max file
/// size**, not the per-chunk packet size. The actual chunk size is the
/// ML-negotiated `maxPacketSize` (defaults to 375), which the caller already
/// has from device-info exchange. Mistaking these caused large uploads to be
/// emitted as a single oversized GFDI frame the watch couldn't reassemble.
public struct UploadRequestStatus: Sendable {
    public enum Status: UInt8, Sendable {
        case ok = 0
        case indexUnknown = 1
        case indexNotWriteable = 2
        case noSpace = 3
        case invalid = 4
        case notReady = 5
        case crcIncorrect = 6
        case unknown = 255
    }

    public let status: UInt8
    public let uploadStatus: Status
    public let dataOffset: UInt32
    public let maxFileSize: UInt32
    public let crcSeed: UInt16

    public var canProceed: Bool {
        status == 0 && uploadStatus == .ok && dataOffset == 0
    }

    /// Decode from a RESPONSE(5000) message whose originalType is uploadRequest(5003).
    public static func decode(from msg: GFDIMessage) throws -> UploadRequestStatus {
        var reader = ByteReader(data: msg.payload)
        _ = try reader.readUInt16LE()   // originalType (5003)
        let outerStatus = try reader.readUInt8()
        let rawUploadStatus = try reader.readUInt8()
        let dataOffset = try reader.readUInt32LE()
        let maxFileSize = try reader.readUInt32LE()
        let crcSeed = try reader.readUInt16LE()
        let uploadStatus = Status(rawValue: rawUploadStatus) ?? .unknown
        return UploadRequestStatus(
            status: outerStatus,
            uploadStatus: uploadStatus,
            dataOffset: dataOffset,
            maxFileSize: maxFileSize,
            crcSeed: crcSeed
        )
    }
}

// MARK: - FileTransferDataChunk (5004, phone → watch, for upload)

/// One chunk of file data sent to the watch during an upload.
/// This is the phone → watch variant of FileTransferDataMessage (which is watch → phone).
///
/// Wire format (payload):
/// ```
/// [flags: UInt8]           0x00 = middle chunk, 0x08 = last chunk, 0x0C = abort
/// [chunkCRC: UInt16 LE]    running CRC over bytes sent so far (including this chunk)
/// [dataOffset: UInt32 LE]  absolute byte offset of this chunk
/// [data: remaining bytes]  chunk payload
/// ```
///
/// Field order matches the watch → phone `FileTransferDataMessage` (CRC before
/// offset). Reversing them causes the watch to parse `dataOffset` as the CRC
/// and reply with `transferStatus=4 (offsetMismatch), nextDataOffset=0`.
///
/// Note: The `chunkCRC` is the cumulative CRC, computed with `CRC16.compute(data: chunkData, seed: previousCRC)`.
public struct FileTransferDataChunk: Sendable {
    public enum Flags: UInt8, Sendable {
        case middle = 0x00
        case last = 0x08
        case abort = 0x0C
    }

    public let flags: Flags
    public let dataOffset: UInt32
    public let chunkCRC: UInt16
    public let data: Data

    public init(flags: Flags = .middle, dataOffset: UInt32, chunkCRC: UInt16, data: Data) {
        self.flags = flags
        self.dataOffset = dataOffset
        self.chunkCRC = chunkCRC
        self.data = data
    }

    public func toMessage() -> GFDIMessage {
        var payload = Data()
        payload.append(flags.rawValue)
        payload.appendUInt16LE(chunkCRC)
        payload.appendUInt32LE(dataOffset)
        payload.append(data)
        return GFDIMessage(type: .fileTransferData, payload: payload)
    }
}

// MARK: - FileTransferDataUploadACK (watch → phone, per-chunk during upload)

/// Per-chunk acknowledgement from the watch during an upload.
/// Arrives as a full RESPONSE(5000) frame, not compact-typed.
///
/// Wire format (RESPONSE payload):
/// ```
/// [originalType: UInt16 LE = 5004]
/// [outerStatus: UInt8 = 0 ACK]
/// [transferStatus: UInt8]  0=OK, 1=RESEND, 2=ABORT, 3=CRC_MISMATCH, ...
/// [nextDataOffset: UInt32 LE] next byte the watch expects
/// ```
public struct FileTransferDataUploadACK: Sendable {
    public enum TransferStatus: UInt8, Sendable {
        case ok = 0
        case resend = 1
        case abort = 2
        case crcMismatch = 3
        case offsetMismatch = 4
        case unknown = 255
    }

    public let transferStatus: TransferStatus
    public let nextDataOffset: UInt32

    public var isOK: Bool {
        transferStatus == .ok
    }

    /// Decode from a RESPONSE(5000) message whose originalType is fileTransferData(5004)
    /// during an upload.
    public static func decode(from msg: GFDIMessage) throws -> FileTransferDataUploadACK {
        var reader = ByteReader(data: msg.payload)
        _ = try reader.readUInt16LE()   // originalType (5004)
        _ = try reader.readUInt8()      // outerStatus
        let rawTransferStatus = try reader.readUInt8()
        let nextDataOffset = try reader.readUInt32LE()
        let transferStatus = TransferStatus(rawValue: rawTransferStatus) ?? .unknown
        return FileTransferDataUploadACK(
            transferStatus: transferStatus,
            nextDataOffset: nextDataOffset
        )
    }
}

