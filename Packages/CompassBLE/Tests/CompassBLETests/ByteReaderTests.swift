import Testing
import Foundation
@testable import CompassBLE

/// Tests for the little-endian byte reader.
@Suite("ByteReader Tests")
struct ByteReaderTests {

    @Test("Read UInt8")
    func readUInt8() throws {
        var reader = ByteReader(data: Data([0x42]))
        let value = try reader.readUInt8()
        #expect(value == 0x42)
        #expect(reader.remaining == 0)
        #expect(reader.isAtEnd)
    }

    @Test("Read UInt16 little-endian")
    func readUInt16LE() throws {
        // 0x0100 in LE is [0x00, 0x01] = 256
        var reader = ByteReader(data: Data([0x00, 0x01]))
        let value = try reader.readUInt16LE()
        #expect(value == 256)
    }

    @Test("Read UInt16 little-endian — low byte first")
    func readUInt16LELowFirst() throws {
        // [0x04, 0x50] = 0x5004
        var reader = ByteReader(data: Data([0x04, 0x50]))
        let value = try reader.readUInt16LE()
        #expect(value == 0x5004)
    }

    @Test("Read UInt32 little-endian")
    func readUInt32LE() throws {
        // [0x78, 0x56, 0x34, 0x12] = 0x12345678
        var reader = ByteReader(data: Data([0x78, 0x56, 0x34, 0x12]))
        let value = try reader.readUInt32LE()
        #expect(value == 0x12345678)
    }

    @Test("Read Int16 little-endian — positive")
    func readInt16LEPositive() throws {
        // [0x01, 0x00] = 1
        var reader = ByteReader(data: Data([0x01, 0x00]))
        let value = try reader.readInt16LE()
        #expect(value == 1)
    }

    @Test("Read Int16 little-endian — negative")
    func readInt16LENegative() throws {
        // -1 = 0xFFFF in UInt16, LE = [0xFF, 0xFF]
        var reader = ByteReader(data: Data([0xFF, 0xFF]))
        let value = try reader.readInt16LE()
        #expect(value == -1)
    }

    @Test("Read bytes")
    func readBytes() throws {
        var reader = ByteReader(data: Data([0x01, 0x02, 0x03, 0x04, 0x05]))
        let bytes = try reader.readBytes(3)
        #expect(bytes == Data([0x01, 0x02, 0x03]))
        #expect(reader.remaining == 2)
    }

    @Test("Read string — null terminated")
    func readStringNullTerminated() throws {
        var data = Data("Hello".utf8)
        data.append(contentsOf: [0x00, 0x00, 0x00]) // Null padding
        var reader = ByteReader(data: data)
        let string = try reader.readString(8)
        #expect(string == "Hello")
    }

    @Test("Read string — no null terminator")
    func readStringNoNull() throws {
        let data = Data("Hi".utf8)
        var reader = ByteReader(data: data)
        let string = try reader.readString(2)
        #expect(string == "Hi")
    }

    @Test("Sequential reads advance offset")
    func sequentialReads() throws {
        let data = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])
        var reader = ByteReader(data: data)

        let byte = try reader.readUInt8()
        #expect(byte == 0x01)
        #expect(reader.offset == 1)

        let word = try reader.readUInt16LE()
        #expect(word == 0x0302) // [0x02, 0x03] LE
        #expect(reader.offset == 3)

        let dword = try reader.readUInt32LE()
        #expect(dword == 0x07060504) // [0x04, 0x05, 0x06, 0x07] LE
        #expect(reader.offset == 7)
        #expect(reader.isAtEnd)
    }

    @Test("Insufficient data throws error")
    func insufficientData() throws {
        var reader = ByteReader(data: Data([0x01]))
        #expect(throws: ByteReader.Error.self) {
            _ = try reader.readUInt16LE()
        }
    }

    @Test("Read bytes with insufficient data throws error")
    func readBytesInsufficient() throws {
        var reader = ByteReader(data: Data([0x01, 0x02]))
        #expect(throws: ByteReader.Error.self) {
            _ = try reader.readBytes(5)
        }
    }

    @Test("Empty reader has zero remaining")
    func emptyReader() {
        let reader = ByteReader(data: Data())
        #expect(reader.remaining == 0)
        #expect(reader.isAtEnd)
    }

    @Test("Remaining decreases correctly")
    func remainingDecreases() throws {
        var reader = ByteReader(data: Data([0x01, 0x02, 0x03, 0x04]))
        #expect(reader.remaining == 4)
        _ = try reader.readUInt8()
        #expect(reader.remaining == 3)
        _ = try reader.readUInt16LE()
        #expect(reader.remaining == 1)
    }
}
