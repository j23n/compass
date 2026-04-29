import Foundation

/// A Garmin GFDI (Garmin Flexible and Interoperable Data Interface) message.
///
/// ## Wire Format
///
/// ```
/// [length: UInt16 LE][type: UInt16 LE][payload: variable][crc16: UInt16 LE]
/// ```
///
/// - `length`: Total message size in bytes, including the length field itself.
///   Minimum value is 6 (2 length + 2 type + 0 payload + 2 CRC).
/// - `type`: The ``GFDIMessageType`` identifying this message.
/// - `payload`: Variable-length message-specific data.
/// - `crc16`: CRC-16-CCITT computed over the length, type, and payload bytes
///   (everything except the CRC itself).
///
/// The CRC is validated on decode and computed on encode. Messages with invalid
/// CRCs are rejected by the watch.
///
/// Reference: Gadgetbridge `GFDIMessage.java` — message encoding/decoding.
public struct GFDIMessage: Sendable, Equatable {

    /// The message type code.
    public let type: GFDIMessageType

    /// The message-specific payload bytes (between the type and CRC fields).
    public let payload: Data

    /// Create a GFDI message with the given type and payload.
    public init(type: GFDIMessageType, payload: Data = Data()) {
        self.type = type
        self.payload = payload
    }

    // MARK: - Encode

    /// Encode this message to its wire format representation.
    ///
    /// Produces: `[length LE 16][type LE 16][payload][CRC16 LE 16]`
    ///
    /// - Returns: The complete wire-format bytes ready to send.
    public func encode() -> Data {
        // Total length = 2 (length) + 2 (type) + payload + 2 (CRC)
        let totalLength = UInt16(6 + payload.count)

        var data = Data(capacity: Int(totalLength))

        // Length (LE)
        data.append(UInt8(totalLength & 0xFF))
        data.append(UInt8(totalLength >> 8))

        // Type (LE)
        data.append(UInt8(type.rawValue & 0xFF))
        data.append(UInt8(type.rawValue >> 8))

        // Payload
        data.append(payload)

        // CRC over everything so far (length + type + payload)
        let crc = CRC16.compute(data: data)
        data.append(UInt8(crc & 0xFF))
        data.append(UInt8(crc >> 8))

        return data
    }

    // MARK: - Decode

    /// Errors that can occur during message decoding.
    public enum DecodeError: Error, Sendable {
        /// The data is shorter than the minimum GFDI message size (6 bytes).
        case messageTooShort(length: Int)

        /// The length field doesn't match the actual data size.
        case lengthMismatch(expected: Int, actual: Int)

        /// The CRC check failed.
        case crcMismatch(expected: UInt16, computed: UInt16)

        /// The message type code is not recognized.
        case unknownType(rawValue: UInt16)
    }

    /// Decode a GFDI message from wire-format bytes.
    ///
    /// Validates the length field and CRC before returning.
    ///
    /// - Parameter data: The raw wire-format bytes.
    /// - Returns: The decoded message.
    /// - Throws: ``DecodeError`` if the data is invalid.
    public static func decode(from data: Data) throws -> GFDIMessage {
        guard data.count >= 6 else {
            throw DecodeError.messageTooShort(length: data.count)
        }

        let start = data.startIndex

        // Read length (LE)
        let length = Int(data[start]) | (Int(data[start + 1]) << 8)

        guard data.count >= length else {
            throw DecodeError.lengthMismatch(expected: length, actual: data.count)
        }

        // Read type (LE). Garmin supports a compact encoding where the high
        // bit signals (raw & 0xFF) + 5000 — see Gadgetbridge GFDIMessage.parseIncoming.
        var rawType = UInt16(data[start + 2]) | (UInt16(data[start + 3]) << 8)
        if rawType & 0x8000 != 0 {
            rawType = (rawType & 0x00FF) &+ 5000
        }

        // Extract payload (between type and CRC)
        let payloadStart = start + 4
        let payloadEnd = start + length - 2
        let payload: Data
        if payloadEnd > payloadStart {
            payload = Data(data[payloadStart..<payloadEnd])
        } else {
            payload = Data()
        }

        // Read CRC (last 2 bytes of the message)
        let crcStart = start + length - 2
        let expectedCRC = UInt16(data[crcStart]) | (UInt16(data[crcStart + 1]) << 8)

        // Compute CRC over length + type + payload
        let crcData = Data(data[start..<(start + length - 2)])
        let computedCRC = CRC16.compute(data: crcData)

        guard expectedCRC == computedCRC else {
            throw DecodeError.crcMismatch(expected: expectedCRC, computed: computedCRC)
        }

        // Resolve message type
        guard let messageType = GFDIMessageType(rawValue: rawType) else {
            throw DecodeError.unknownType(rawValue: rawType)
        }

        return GFDIMessage(type: messageType, payload: payload)
    }
}
