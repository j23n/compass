import Foundation

/// Generic GFDI RESPONSE (5000 / 0x1388) used to ACK any incoming message.
///
/// Wire format (payload):
/// ```
/// [originalType: UInt16 LE]
/// [status: UInt8]            // 0 = ACK, 1 = NACK, etc.
/// [additional bytes]         // varies by originalType (e.g., DEVICE_INFORMATION echoes host info)
/// ```
///
/// Reference: Gadgetbridge `GFDIStatusMessage.java`
public struct GFDIResponse: Sendable {

    /// Status codes mirroring Gadgetbridge `GFDIStatusMessage.Status`.
    public enum Status: UInt8, Sendable {
        case ack = 0
        case nack = 1
        case unsupported = 2
        case decodeError = 3
        case crcError = 4
        case lengthError = 5
    }

    /// The type of the message being acknowledged.
    public let originalType: GFDIMessageType

    /// The status byte.
    public let status: Status

    /// Any additional bytes following the status (per originalType).
    public let additionalPayload: Data

    public init(
        originalType: GFDIMessageType,
        status: Status = .ack,
        additionalPayload: Data = Data()
    ) {
        self.originalType = originalType
        self.status = status
        self.additionalPayload = additionalPayload
    }

    public func encode() -> Data {
        var data = Data(capacity: 3 + additionalPayload.count)
        data.appendUInt16LE(originalType.rawValue)
        data.append(status.rawValue)
        data.append(additionalPayload)
        return data
    }

    public func toMessage() -> GFDIMessage {
        GFDIMessage(type: .response, payload: encode())
    }

    /// Decoded fields from an incoming RESPONSE payload.
    public struct Decoded: Sendable {
        public let originalType: UInt16
        public let status: UInt8
        public let remaining: Data
    }

    public static func decode(from data: Data) throws -> Decoded {
        var reader = ByteReader(data: data)
        let originalType = try reader.readUInt16LE()
        let status = try reader.readUInt8()
        let remaining: Data
        if reader.remaining > 0 {
            remaining = try reader.readBytes(reader.remaining)
        } else {
            remaining = Data()
        }
        return Decoded(originalType: originalType, status: status, remaining: remaining)
    }
}
