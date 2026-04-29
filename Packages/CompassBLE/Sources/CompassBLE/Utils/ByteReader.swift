import Foundation

/// A cursor-based reader for little-endian binary data.
///
/// Used throughout CompassBLE to parse GFDI message payloads, MLR headers,
/// and FIT file metadata. All multi-byte reads are little-endian, matching
/// the Garmin wire format.
///
/// Usage:
/// ```swift
/// var reader = ByteReader(data: someData)
/// let version = try reader.readUInt16LE()
/// let name = try reader.readString(16)
/// ```
public struct ByteReader: Sendable {

    /// Error thrown when a read would exceed the available data.
    public enum Error: Swift.Error, Sendable {
        case insufficientData(needed: Int, available: Int)
        case invalidUTF8
    }

    private let data: Data

    /// The current read position in the data buffer.
    public private(set) var offset: Int = 0

    /// Creates a reader over the given data, starting at offset 0.
    public init(data: Data) {
        self.data = data
    }

    /// The number of bytes remaining from the current offset to the end.
    public var remaining: Int {
        max(0, data.count - offset)
    }

    /// Whether the reader has consumed all available data.
    public var isAtEnd: Bool {
        offset >= data.count
    }

    // MARK: - Read Primitives

    /// Read a single unsigned byte and advance the cursor.
    public mutating func readUInt8() throws -> UInt8 {
        guard remaining >= 1 else {
            throw Error.insufficientData(needed: 1, available: remaining)
        }
        let value = data[data.startIndex + offset]
        offset += 1
        return value
    }

    /// Read a little-endian UInt16 and advance the cursor by 2.
    public mutating func readUInt16LE() throws -> UInt16 {
        guard remaining >= 2 else {
            throw Error.insufficientData(needed: 2, available: remaining)
        }
        let start = data.startIndex + offset
        let lo = UInt16(data[start])
        let hi = UInt16(data[start + 1])
        offset += 2
        return lo | (hi << 8)
    }

    /// Read a little-endian UInt32 and advance the cursor by 4.
    public mutating func readUInt32LE() throws -> UInt32 {
        guard remaining >= 4 else {
            throw Error.insufficientData(needed: 4, available: remaining)
        }
        let start = data.startIndex + offset
        let b0 = UInt32(data[start])
        let b1 = UInt32(data[start + 1])
        let b2 = UInt32(data[start + 2])
        let b3 = UInt32(data[start + 3])
        offset += 4
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    /// Read a little-endian Int16 and advance the cursor by 2.
    public mutating func readInt16LE() throws -> Int16 {
        let raw = try readUInt16LE()
        return Int16(bitPattern: raw)
    }

    /// Read a signed byte (Int8) and advance the cursor by 1.
    public mutating func readInt8() throws -> Int8 {
        Int8(bitPattern: try readUInt8())
    }

    /// Read a little-endian Int32 and advance the cursor by 4.
    public mutating func readInt32LE() throws -> Int32 {
        Int32(bitPattern: try readUInt32LE())
    }

    /// Read `count` raw bytes and advance the cursor.
    public mutating func readBytes(_ count: Int) throws -> Data {
        guard remaining >= count else {
            throw Error.insufficientData(needed: count, available: remaining)
        }
        let start = data.startIndex + offset
        let result = data[start..<(start + count)]
        offset += count
        return Data(result)
    }

    /// Read `count` bytes as a UTF-8 string, trimming null terminators.
    public mutating func readString(_ count: Int) throws -> String {
        let bytes = try readBytes(count)
        // Trim trailing nulls
        let trimmed = bytes.prefix(while: { $0 != 0 })
        guard let string = String(data: Data(trimmed), encoding: .utf8) else {
            throw Error.invalidUTF8
        }
        return string
    }

    /// Read a length-prefixed UTF-8 string (1-byte length, no terminator).
    /// Matches Gadgetbridge `MessageWriter.writeString` / reader format.
    public mutating func readLengthPrefixedString() throws -> String {
        let length = Int(try readUInt8())
        if length == 0 { return "" }
        let bytes = try readBytes(length)
        guard let string = String(data: bytes, encoding: .utf8) else {
            throw Error.invalidUTF8
        }
        return string
    }
}
