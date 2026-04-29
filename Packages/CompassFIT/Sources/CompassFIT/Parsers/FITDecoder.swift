import Foundation
import os

// MARK: - Public types

/// A decoded FIT file containing an ordered list of data messages.
public struct FITFile: Sendable {
    public let messages: [FITMessage]

    public init(messages: [FITMessage]) {
        self.messages = messages
    }
}

/// A single data message from a FIT file.
public struct FITMessage: Sendable {
    public let globalMessageNumber: UInt16
    public let fields: [UInt8: FITFieldValue]

    public init(globalMessageNumber: UInt16, fields: [UInt8: FITFieldValue]) {
        self.globalMessageNumber = globalMessageNumber
        self.fields = fields
    }
}

/// A typed field value from a FIT data message.
public enum FITFieldValue: Sendable, Equatable {
    case uint8(UInt8)
    case int8(Int8)
    case uint16(UInt16)
    case int16(Int16)
    case uint32(UInt32)
    case int32(Int32)
    case uint64(UInt64)
    case int64(Int64)
    case float32(Float)
    case float64(Double)
    case string(String)
    case enumValue(UInt8)
    case data(Data)

    /// Returns the value as a `Double`, if a numeric conversion is possible.
    public var doubleValue: Double? {
        switch self {
        case .uint8(let v):   Double(v)
        case .int8(let v):    Double(v)
        case .uint16(let v):  Double(v)
        case .int16(let v):   Double(v)
        case .uint32(let v):  Double(v)
        case .int32(let v):   Double(v)
        case .uint64(let v):  Double(v)
        case .int64(let v):   Double(v)
        case .float32(let v): Double(v)
        case .float64(let v): v
        case .enumValue(let v): Double(v)
        case .string, .data:  nil
        }
    }

    /// Returns the value as an `Int`, if a numeric conversion is possible.
    public var intValue: Int? {
        switch self {
        case .uint8(let v):   Int(v)
        case .int8(let v):    Int(v)
        case .uint16(let v):  Int(v)
        case .int16(let v):   Int(v)
        case .uint32(let v):  Int(v)
        case .int32(let v):   Int(v)
        case .uint64(let v):  Int(v)
        case .int64(let v):   Int(v)
        case .float32(let v): Int(v)
        case .float64(let v): Int(v)
        case .enumValue(let v): Int(v)
        case .string, .data:  nil
        }
    }

    /// Returns the value as a `UInt32`, if a numeric conversion is possible.
    public var uint32Value: UInt32? {
        switch self {
        case .uint8(let v):   UInt32(v)
        case .int8(let v):    v >= 0 ? UInt32(v) : nil
        case .uint16(let v):  UInt32(v)
        case .int16(let v):   v >= 0 ? UInt32(v) : nil
        case .uint32(let v):  v
        case .int32(let v):   v >= 0 ? UInt32(v) : nil
        case .uint64(let v):  v <= UInt32.max ? UInt32(v) : nil
        case .int64(let v):   (v >= 0 && v <= Int64(UInt32.max)) ? UInt32(v) : nil
        case .float32(let v): UInt32(v)
        case .float64(let v): UInt32(v)
        case .enumValue(let v): UInt32(v)
        case .string, .data:  nil
        }
    }

    /// Returns the value as a `String`, if it is a string variant.
    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// Returns the value as an array of `UInt8`.
    /// Handles both a scalar `.uint8` (returns single-element array) and a
    /// `.data` blob (array of uint8 elements, as used in HSA messages).
    public var uint8Array: [UInt8]? {
        switch self {
        case .uint8(let v):   return [v]
        case .data(let bytes): return bytes.isEmpty ? nil : Array(bytes)
        default: return nil
        }
    }

    /// Returns the value as an array of `Int8`.
    /// Handles both a scalar `.int8` and a `.data` blob (array of sint8 elements,
    /// as used in HSA stress/body-battery messages).
    public var int8Array: [Int8]? {
        switch self {
        case .int8(let v):    return [v]
        case .data(let bytes): return bytes.isEmpty ? nil : bytes.map { Int8(bitPattern: $0) }
        default: return nil
        }
    }
}

// MARK: - Errors

public enum FITDecoderError: Error, Sendable {
    case invalidHeader
    case invalidDataSignature
    case unexpectedEndOfData
    case invalidFieldType(UInt8)
    case crcMismatch
}

// MARK: - FITDecoder

/// A self-contained decoder for the ANT+ FIT binary file format.
///
/// Supports the standard 14-byte header, definition messages, data messages,
/// compressed timestamps, and both little-endian and big-endian architectures.
public struct FITDecoder: Sendable {

    private static let logger = Logger(subsystem: "com.compass.fit", category: "FITDecoder")

    public init() {}

    // MARK: - Public API

    /// Decodes a FIT file from raw data.
    public func decode(data: Data) throws -> FITFile {
        var reader = FITReader(data: data)
        let header = try readHeader(&reader)

        let dataEnd = Int(header.headerSize) + Int(header.dataSize)
        guard data.count >= dataEnd else {
            throw FITDecoderError.unexpectedEndOfData
        }

        // Local message definitions (keyed by local message type 0-15).
        var definitions: [UInt8: LocalMessageDefinition] = [:]
        var messages: [FITMessage] = []
        // Last absolute Garmin-epoch timestamp seen, used to resolve compressed timestamps.
        var lastTimestamp: UInt32 = 0

        while reader.offset < dataEnd {
            let recordHeader = reader.readUInt8()

            // Bit 7 distinguishes normal header (0) from compressed-timestamp header (1).
            if recordHeader & 0x80 != 0 {
                // Compressed timestamp data message.
                // Bits 6-5 = local message type (0-3); bits 4-0 = 5-bit time offset.
                let localType = (recordHeader >> 5) & 0x03
                let timeOffset = UInt32(recordHeader & 0x1F)
                guard let def = definitions[localType] else {
                    Self.logger.warning("Compressed timestamp references undefined local type \(localType), skipping")
                    continue
                }
                var message = try readDataMessage(&reader, definition: def)
                // Resolve the implied absolute timestamp per FIT SDK §3.3.7:
                // if offset >= (lastTS & 0x1F) the upper bits stay; otherwise they increment by 32.
                let maskedLast = lastTimestamp & 0x1F
                let newTimestamp: UInt32
                if timeOffset >= maskedLast {
                    newTimestamp = (lastTimestamp & ~UInt32(0x1F)) | timeOffset
                } else {
                    newTimestamp = ((lastTimestamp & ~UInt32(0x1F)) &+ 0x20) | timeOffset
                }
                lastTimestamp = newTimestamp
                // Inject field 253 (timestamp) so parsers can use it normally.
                if message.fields[253] == nil {
                    var fields = message.fields
                    fields[253] = .uint32(newTimestamp)
                    message = FITMessage(globalMessageNumber: message.globalMessageNumber, fields: fields)
                }
                messages.append(message)
            } else if recordHeader & 0x40 != 0 {
                // Definition message
                let localType = recordHeader & 0x0F
                let definition = try readDefinitionMessage(&reader, header: recordHeader)
                definitions[localType] = definition
            } else {
                // Normal data message
                let localType = recordHeader & 0x0F
                guard let def = definitions[localType] else {
                    Self.logger.warning("Data message references undefined local type \(localType), skipping")
                    continue
                }
                let message = try readDataMessage(&reader, definition: def)
                // Track the last absolute timestamp for compressed-timestamp resolution.
                if let tsField = message.fields[253], case .uint32(let tsVal) = tsField {
                    lastTimestamp = tsVal
                }
                messages.append(message)
            }
        }

        return FITFile(messages: messages)
    }

    // MARK: - Header

    /// The parsed 14-byte FIT file header.
    struct FITHeader {
        let headerSize: UInt8
        let protocolVersion: UInt8
        let profileVersion: UInt16
        let dataSize: UInt32
        let dataType: String // ".FIT"
    }

    private func readHeader(_ reader: inout FITReader) throws -> FITHeader {
        guard reader.remaining >= 12 else {
            throw FITDecoderError.invalidHeader
        }
        let headerSize = reader.readUInt8()
        let protocolVersion = reader.readUInt8()
        let profileVersion = reader.readUInt16LE()
        let dataSize = reader.readUInt32LE()

        // Data type signature: ".FIT" (ASCII)
        let sig0 = reader.readUInt8()
        let sig1 = reader.readUInt8()
        let sig2 = reader.readUInt8()
        let sig3 = reader.readUInt8()
        let signature = String(bytes: [sig0, sig1, sig2, sig3], encoding: .ascii) ?? ""
        guard signature == ".FIT" else {
            throw FITDecoderError.invalidDataSignature
        }

        // If 14-byte header, skip the 2-byte header CRC.
        if headerSize == 14 {
            _ = reader.readUInt16LE() // header CRC
        } else if headerSize > 12 {
            // Skip any extra header bytes beyond 12 that aren't the standard 14.
            let extra = Int(headerSize) - 12
            reader.skip(extra)
        }

        return FITHeader(
            headerSize: headerSize,
            protocolVersion: protocolVersion,
            profileVersion: profileVersion,
            dataSize: dataSize,
            dataType: signature
        )
    }

    // MARK: - Definition message

    struct FieldDef {
        let fieldDefNum: UInt8
        let size: UInt8
        let baseType: UInt8
    }

    struct DevFieldDef {
        let fieldNum: UInt8
        let size: UInt8
        let devDataIndex: UInt8
    }

    struct LocalMessageDefinition {
        let architecture: UInt8 // 0 = little-endian, 1 = big-endian
        let globalMessageNumber: UInt16
        let fieldDefs: [FieldDef]
        let devFieldDefs: [DevFieldDef]
    }

    private func readDefinitionMessage(_ reader: inout FITReader, header: UInt8) throws -> LocalMessageDefinition {
        let hasDeveloperData = (header & 0x20) != 0

        _ = reader.readUInt8() // reserved byte
        let architecture = reader.readUInt8()
        let globalMessageNumber: UInt16
        if architecture == 0 {
            globalMessageNumber = reader.readUInt16LE()
        } else {
            globalMessageNumber = reader.readUInt16BE()
        }
        let numFields = reader.readUInt8()
        var fieldDefs: [FieldDef] = []
        fieldDefs.reserveCapacity(Int(numFields))

        for _ in 0..<numFields {
            let defNum = reader.readUInt8()
            let size = reader.readUInt8()
            let baseType = reader.readUInt8()
            fieldDefs.append(FieldDef(fieldDefNum: defNum, size: size, baseType: baseType))
        }

        var devFieldDefs: [DevFieldDef] = []
        if hasDeveloperData {
            let numDevFields = reader.readUInt8()
            devFieldDefs.reserveCapacity(Int(numDevFields))
            for _ in 0..<numDevFields {
                let fieldNum = reader.readUInt8()
                let size = reader.readUInt8()
                let devDataIndex = reader.readUInt8()
                devFieldDefs.append(DevFieldDef(fieldNum: fieldNum, size: size, devDataIndex: devDataIndex))
            }
        }

        return LocalMessageDefinition(
            architecture: architecture,
            globalMessageNumber: globalMessageNumber,
            fieldDefs: fieldDefs,
            devFieldDefs: devFieldDefs
        )
    }

    // MARK: - Data message

    private func readDataMessage(_ reader: inout FITReader, definition: LocalMessageDefinition) throws -> FITMessage {
        let bigEndian = definition.architecture != 0
        var fields: [UInt8: FITFieldValue] = [:]

        for fieldDef in definition.fieldDefs {
            guard reader.remaining >= Int(fieldDef.size) else {
                throw FITDecoderError.unexpectedEndOfData
            }
            let value = readFieldValue(&reader, size: fieldDef.size, baseType: fieldDef.baseType, bigEndian: bigEndian)
            fields[fieldDef.fieldDefNum] = value
        }

        // Skip developer fields (we store them as raw data but don't interpret them).
        for devFieldDef in definition.devFieldDefs {
            guard reader.remaining >= Int(devFieldDef.size) else {
                throw FITDecoderError.unexpectedEndOfData
            }
            reader.skip(Int(devFieldDef.size))
        }

        return FITMessage(globalMessageNumber: definition.globalMessageNumber, fields: fields)
    }

    // MARK: - Field value reading

    /// FIT base type numbers (lower 5 bits).
    private enum BaseType: UInt8 {
        case fitEnum    = 0x00
        case sint8      = 0x01
        case uint8      = 0x02
        case sint16     = 0x83
        case uint16     = 0x84
        case sint32     = 0x85
        case uint32     = 0x86
        case string     = 0x07
        case float32    = 0x88
        case float64    = 0x89
        case uint8z     = 0x0A
        case uint16z    = 0x8B
        case uint32z    = 0x8C
        case bytes      = 0x0D
        case sint64     = 0x8E
        case uint64     = 0x8F
        case uint64z    = 0x90
    }

    private func readFieldValue(_ reader: inout FITReader, size: UInt8, baseType: UInt8, bigEndian: Bool) -> FITFieldValue {
        let typeNum = baseType

        switch typeNum {
        case BaseType.fitEnum.rawValue:
            if size == 1 {
                return .enumValue(reader.readUInt8())
            }
            return .data(reader.readData(Int(size)))

        case BaseType.sint8.rawValue:
            if size == 1 {
                return .int8(Int8(bitPattern: reader.readUInt8()))
            }
            return .data(reader.readData(Int(size)))

        case BaseType.uint8.rawValue, BaseType.uint8z.rawValue:
            if size == 1 {
                return .uint8(reader.readUInt8())
            }
            return .data(reader.readData(Int(size)))

        case BaseType.sint16.rawValue:
            if size == 2 {
                let raw = bigEndian ? reader.readUInt16BE() : reader.readUInt16LE()
                return .int16(Int16(bitPattern: raw))
            }
            return .data(reader.readData(Int(size)))

        case BaseType.uint16.rawValue, BaseType.uint16z.rawValue:
            if size == 2 {
                return .uint16(bigEndian ? reader.readUInt16BE() : reader.readUInt16LE())
            }
            return .data(reader.readData(Int(size)))

        case BaseType.sint32.rawValue:
            if size == 4 {
                let raw = bigEndian ? reader.readUInt32BE() : reader.readUInt32LE()
                return .int32(Int32(bitPattern: raw))
            }
            return .data(reader.readData(Int(size)))

        case BaseType.uint32.rawValue, BaseType.uint32z.rawValue:
            if size == 4 {
                return .uint32(bigEndian ? reader.readUInt32BE() : reader.readUInt32LE())
            }
            return .data(reader.readData(Int(size)))

        case BaseType.float32.rawValue:
            if size == 4 {
                let raw = bigEndian ? reader.readUInt32BE() : reader.readUInt32LE()
                return .float32(Float(bitPattern: raw))
            }
            return .data(reader.readData(Int(size)))

        case BaseType.float64.rawValue:
            if size == 8 {
                let raw = bigEndian ? reader.readUInt64BE() : reader.readUInt64LE()
                return .float64(Double(bitPattern: raw))
            }
            return .data(reader.readData(Int(size)))

        case BaseType.string.rawValue:
            let bytes = reader.readData(Int(size))
            // FIT strings are null-terminated; strip trailing nulls.
            let trimmed = bytes.prefix(while: { $0 != 0 })
            let str = String(data: Data(trimmed), encoding: .utf8) ?? ""
            return .string(str)

        case BaseType.sint64.rawValue:
            if size == 8 {
                let raw = bigEndian ? reader.readUInt64BE() : reader.readUInt64LE()
                return .int64(Int64(bitPattern: raw))
            }
            return .data(reader.readData(Int(size)))

        case BaseType.uint64.rawValue, BaseType.uint64z.rawValue:
            if size == 8 {
                return .uint64(bigEndian ? reader.readUInt64BE() : reader.readUInt64LE())
            }
            return .data(reader.readData(Int(size)))

        case BaseType.bytes.rawValue:
            return .data(reader.readData(Int(size)))

        default:
            // Unknown base type - read raw bytes.
            return .data(reader.readData(Int(size)))
        }
    }
}

// MARK: - FITReader (cursor over Data)

/// A lightweight cursor for reading binary data sequentially.
struct FITReader: ~Copyable {
    private let data: Data
    private(set) var offset: Int

    var remaining: Int { data.count - offset }

    init(data: Data) {
        self.data = data
        self.offset = 0
    }

    mutating func readUInt8() -> UInt8 {
        let value = data[data.startIndex + offset]
        offset += 1
        return value
    }

    mutating func readUInt16LE() -> UInt16 {
        let b0 = UInt16(data[data.startIndex + offset])
        let b1 = UInt16(data[data.startIndex + offset + 1])
        offset += 2
        return b0 | (b1 << 8)
    }

    mutating func readUInt16BE() -> UInt16 {
        let b0 = UInt16(data[data.startIndex + offset])
        let b1 = UInt16(data[data.startIndex + offset + 1])
        offset += 2
        return (b0 << 8) | b1
    }

    mutating func readUInt32LE() -> UInt32 {
        let b0 = UInt32(data[data.startIndex + offset])
        let b1 = UInt32(data[data.startIndex + offset + 1])
        let b2 = UInt32(data[data.startIndex + offset + 2])
        let b3 = UInt32(data[data.startIndex + offset + 3])
        offset += 4
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    mutating func readUInt32BE() -> UInt32 {
        let b0 = UInt32(data[data.startIndex + offset])
        let b1 = UInt32(data[data.startIndex + offset + 1])
        let b2 = UInt32(data[data.startIndex + offset + 2])
        let b3 = UInt32(data[data.startIndex + offset + 3])
        offset += 4
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    mutating func readUInt64LE() -> UInt64 {
        var result: UInt64 = 0
        for i in 0..<8 {
            result |= UInt64(data[data.startIndex + offset + i]) << (i * 8)
        }
        offset += 8
        return result
    }

    mutating func readUInt64BE() -> UInt64 {
        var result: UInt64 = 0
        for i in 0..<8 {
            result |= UInt64(data[data.startIndex + offset + i]) << ((7 - i) * 8)
        }
        offset += 8
        return result
    }

    mutating func readData(_ count: Int) -> Data {
        let range = (data.startIndex + offset)..<(data.startIndex + offset + count)
        offset += count
        return data[range]
    }

    mutating func skip(_ count: Int) {
        offset += count
    }
}

// MARK: - CRC-16 utility for building test FIT files

/// CRC-16 used by the FIT file format.
public enum FITCRC: Sendable {

    /// CRC lookup table for the FIT protocol.
    private static let table: [UInt16] = {
        var t = [UInt16](repeating: 0, count: 16)
        t[0]  = 0x0000; t[1]  = 0xCC01; t[2]  = 0xD801; t[3]  = 0x1400
        t[4]  = 0xF001; t[5]  = 0x3C00; t[6]  = 0x2800; t[7]  = 0xE401
        t[8]  = 0xA001; t[9]  = 0x6C00; t[10] = 0x7800; t[11] = 0xB401
        t[12] = 0x5000; t[13] = 0x9C01; t[14] = 0x8801; t[15] = 0x4400
        return t
    }()

    /// Computes the FIT CRC-16 over the given data.
    public static func compute(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0
        for byte in data {
            // Low nibble
            var tmp = table[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ table[Int(byte & 0xF)]

            // High nibble
            tmp = table[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ table[Int((byte >> 4) & 0xF)]
        }
        return crc
    }
}
