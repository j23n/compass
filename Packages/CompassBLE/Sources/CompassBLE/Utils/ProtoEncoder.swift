import Foundation

/// Minimal protobuf encoder for the wire types used by the Garmin GFDI protobuf channel.
///
/// Supports only the subset needed for Smart/CoreService/LocationUpdatedNotification:
/// - Wire type 0 (varint): uint32, enum, sint32 (zigzag)
/// - Wire type 2 (length-delimited): embedded messages, raw bytes
/// - Wire type 5 (32-bit): float
struct ProtoEncoder {
    private(set) var data = Data()

    // MARK: - Public API

    mutating func writeUInt32(field: Int, value: UInt32) {
        writeTag(field: field, wireType: 0)
        writeVarint(UInt64(value))
    }

    mutating func writeSInt32(field: Int, value: Int32) {
        // Zigzag encoding: (n << 1) ^ (n >> 31)
        let zigzagged = UInt32(bitPattern: (value << 1) ^ (value >> 31))
        writeTag(field: field, wireType: 0)
        writeVarint(UInt64(zigzagged))
    }

    mutating func writeFloat(field: Int, value: Float) {
        writeTag(field: field, wireType: 5)
        let bits = value.bitPattern
        data.append(UInt8(bits & 0xFF))
        data.append(UInt8((bits >> 8) & 0xFF))
        data.append(UInt8((bits >> 16) & 0xFF))
        data.append(UInt8((bits >> 24) & 0xFF))
    }

    mutating func writeEnum(field: Int, value: Int) {
        writeTag(field: field, wireType: 0)
        writeVarint(UInt64(value))
    }

    mutating func writeMessage(field: Int, body: Data) {
        writeTag(field: field, wireType: 2)
        writeVarint(UInt64(body.count))
        data.append(body)
    }

    mutating func writeBytes(field: Int, value: Data) {
        writeTag(field: field, wireType: 2)
        writeVarint(UInt64(value.count))
        data.append(value)
    }

    // MARK: - Primitives

    private mutating func writeTag(field: Int, wireType: Int) {
        writeVarint(UInt64((field << 3) | wireType))
    }

    private mutating func writeVarint(_ value: UInt64) {
        var v = value
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            data.append(byte)
        } while v != 0
    }
}
