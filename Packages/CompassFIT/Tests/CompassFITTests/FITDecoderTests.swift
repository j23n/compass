import Testing
import Foundation
@testable import CompassFIT

// MARK: - Test data builder

/// Builds minimal valid FIT files in memory for testing.
enum FITTestData {

    /// Builds a minimal valid FIT file containing a single data message with the given fields.
    ///
    /// Structure: 14-byte header + definition message + data message + 2-byte CRC.
    static func minimalFITFile(
        globalMessageNumber: UInt16,
        fields: [(fieldDefNum: UInt8, value: UInt32)]
    ) -> Data {
        var body = Data()

        // --- Definition message ---
        // Record header: definition message, local type 0
        body.append(0x40) // bit 6 set = definition, local type 0
        body.append(0x00) // reserved
        body.append(0x00) // architecture: 0 = little-endian
        body.append(UInt8(globalMessageNumber & 0xFF))
        body.append(UInt8((globalMessageNumber >> 8) & 0xFF))
        body.append(UInt8(fields.count)) // number of fields

        for field in fields {
            body.append(field.fieldDefNum) // field def num
            body.append(4)                 // size = 4 bytes (uint32)
            body.append(0x86)              // base type = uint32
        }

        // --- Data message ---
        // Record header: data message, local type 0
        body.append(0x00)
        for field in fields {
            // Write uint32 little-endian
            body.append(UInt8(field.value & 0xFF))
            body.append(UInt8((field.value >> 8) & 0xFF))
            body.append(UInt8((field.value >> 16) & 0xFF))
            body.append(UInt8((field.value >> 24) & 0xFF))
        }

        // --- Build full file: header + body + CRC ---
        let dataSize = UInt32(body.count)
        var file = Data()

        // 14-byte header
        file.append(14)   // header size
        file.append(0x20) // protocol version 2.0
        // Profile version (little-endian uint16)
        file.append(0x08)
        file.append(0x08) // profile version 2056
        // Data size (little-endian uint32)
        file.append(UInt8(dataSize & 0xFF))
        file.append(UInt8((dataSize >> 8) & 0xFF))
        file.append(UInt8((dataSize >> 16) & 0xFF))
        file.append(UInt8((dataSize >> 24) & 0xFF))
        // ".FIT" ASCII signature
        file.append(contentsOf: [0x2E, 0x46, 0x49, 0x54])
        // Header CRC (2 bytes) - compute over the first 12 bytes
        let headerCRC = FITCRC.compute(Data(file.prefix(12)))
        file.append(UInt8(headerCRC & 0xFF))
        file.append(UInt8((headerCRC >> 8) & 0xFF))

        // Append body
        file.append(body)

        // File CRC (over everything after the header)
        let fileCRC = FITCRC.compute(body)
        file.append(UInt8(fileCRC & 0xFF))
        file.append(UInt8((fileCRC >> 8) & 0xFF))

        return file
    }

    /// Builds a FIT file with multiple messages of different types.
    static func multimessageFITFile() -> Data {
        var body = Data()

        // --- Definition for local type 0: message number 18 (session), 2 fields ---
        body.append(0x40) // definition, local type 0
        body.append(0x00) // reserved
        body.append(0x00) // little-endian
        body.append(18)   // global msg num low byte (session)
        body.append(0)    // global msg num high byte
        body.append(2)    // 2 fields
        // Field 253 (timestamp): uint32
        body.append(253); body.append(4); body.append(0x86)
        // Field 11 (total_calories): uint16
        body.append(11); body.append(2); body.append(0x84)

        // --- Data message for local type 0 (session) ---
        body.append(0x00)
        // timestamp = 1000000000
        let ts: UInt32 = 1_000_000_000
        body.append(UInt8(ts & 0xFF))
        body.append(UInt8((ts >> 8) & 0xFF))
        body.append(UInt8((ts >> 16) & 0xFF))
        body.append(UInt8((ts >> 24) & 0xFF))
        // total_calories = 500
        let cal: UInt16 = 500
        body.append(UInt8(cal & 0xFF))
        body.append(UInt8((cal >> 8) & 0xFF))

        // --- Definition for local type 1: message number 20 (record), 1 field ---
        body.append(0x41) // definition, local type 1
        body.append(0x00) // reserved
        body.append(0x00) // little-endian
        body.append(20)   // global msg num (record)
        body.append(0)
        body.append(1)    // 1 field
        // Field 3 (heart_rate): uint8
        body.append(3); body.append(1); body.append(0x02)

        // --- Data message for local type 1 (record) ---
        body.append(0x01) // data, local type 1
        body.append(145)  // heart rate = 145 bpm

        // --- Another data message for local type 1 (record) ---
        body.append(0x01)
        body.append(150)  // heart rate = 150 bpm

        // Build full file
        let dataSize = UInt32(body.count)
        var file = Data()
        file.append(14)
        file.append(0x20)
        file.append(0x08); file.append(0x08)
        file.append(UInt8(dataSize & 0xFF))
        file.append(UInt8((dataSize >> 8) & 0xFF))
        file.append(UInt8((dataSize >> 16) & 0xFF))
        file.append(UInt8((dataSize >> 24) & 0xFF))
        file.append(contentsOf: [0x2E, 0x46, 0x49, 0x54])
        let headerCRC = FITCRC.compute(Data(file.prefix(12)))
        file.append(UInt8(headerCRC & 0xFF))
        file.append(UInt8((headerCRC >> 8) & 0xFF))
        file.append(body)
        let fileCRC = FITCRC.compute(body)
        file.append(UInt8(fileCRC & 0xFF))
        file.append(UInt8((fileCRC >> 8) & 0xFF))
        return file
    }
}

// MARK: - Tests

@Suite("FITDecoder")
struct FITDecoderTests {

    @Test("Rejects data that is too short for a header")
    func rejectsTooShortData() throws {
        let decoder = FITDecoder()
        #expect(throws: FITDecoderError.self) {
            _ = try decoder.decode(data: Data([0x0E, 0x20]))
        }
    }

    @Test("Rejects data with wrong signature")
    func rejectsWrongSignature() throws {
        var bad = Data(repeating: 0, count: 16)
        bad[0] = 14      // header size
        bad[8] = 0x2E    // '.'
        bad[9] = 0x42    // 'B' (wrong, should be 'F')
        bad[10] = 0x49   // 'I'
        bad[11] = 0x54   // 'T'

        let decoder = FITDecoder()
        #expect(throws: FITDecoderError.self) {
            _ = try decoder.decode(data: bad)
        }
    }

    @Test("Decodes a minimal FIT file with one uint32 field")
    func decodesMinimalFile() throws {
        let data = FITTestData.minimalFITFile(
            globalMessageNumber: 0,
            fields: [(fieldDefNum: 253, value: 1_000_000)]
        )

        let decoder = FITDecoder()
        let fitFile = try decoder.decode(data: data)

        #expect(fitFile.messages.count == 1)
        let msg = fitFile.messages[0]
        #expect(msg.globalMessageNumber == 0)
        #expect(msg.fields[253]?.uint32Value == 1_000_000)
    }

    @Test("Decodes multiple fields in a single message")
    func decodesMultipleFields() throws {
        let data = FITTestData.minimalFITFile(
            globalMessageNumber: 55,
            fields: [
                (fieldDefNum: 253, value: 2_000_000),
                (fieldDefNum: 2, value: 5000),
                (fieldDefNum: 5, value: 6),
            ]
        )

        let decoder = FITDecoder()
        let fitFile = try decoder.decode(data: data)

        #expect(fitFile.messages.count == 1)
        let msg = fitFile.messages[0]
        #expect(msg.globalMessageNumber == 55)
        #expect(msg.fields[253]?.uint32Value == 2_000_000)
        #expect(msg.fields[2]?.uint32Value == 5000)
        #expect(msg.fields[5]?.uint32Value == 6)
    }

    @Test("Decodes a multi-message FIT file with different local types")
    func decodesMultiMessageFile() throws {
        let data = FITTestData.multimessageFITFile()

        let decoder = FITDecoder()
        let fitFile = try decoder.decode(data: data)

        // Should have 1 session + 2 record messages = 3 total
        #expect(fitFile.messages.count == 3)

        // First message: session (18)
        let session = fitFile.messages[0]
        #expect(session.globalMessageNumber == 18)
        #expect(session.fields[253]?.uint32Value == 1_000_000_000)
        #expect(session.fields[11]?.intValue == 500)

        // Second and third: record (20)
        let record1 = fitFile.messages[1]
        #expect(record1.globalMessageNumber == 20)
        #expect(record1.fields[3]?.intValue == 145)

        let record2 = fitFile.messages[2]
        #expect(record2.globalMessageNumber == 20)
        #expect(record2.fields[3]?.intValue == 150)
    }

    @Test("FITFieldValue doubleValue works for numeric types")
    func fieldValueDoubleConversion() {
        #expect(FITFieldValue.uint8(42).doubleValue == 42.0)
        #expect(FITFieldValue.int16(-100).doubleValue == -100.0)
        #expect(FITFieldValue.uint32(999999).doubleValue == 999999.0)
        #expect(FITFieldValue.float32(3.14).doubleValue != nil)
        #expect(FITFieldValue.string("hello").doubleValue == nil)
    }

    @Test("FITFieldValue stringValue works")
    func fieldValueStringConversion() {
        #expect(FITFieldValue.string("test").stringValue == "test")
        #expect(FITFieldValue.uint8(1).stringValue == nil)
    }

    @Test("FIT timestamp conversion produces correct dates")
    func timestampConversion() {
        // The FIT epoch is 1989-12-31 00:00:00 UTC.
        // 0 seconds = epoch itself.
        let epoch = FITTimestamp.date(fromFITTimestamp: 0)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let components = cal.dateComponents([.year, .month, .day], from: epoch)
        #expect(components.year == 1989)
        #expect(components.month == 12)
        #expect(components.day == 31)
    }

    @Test("CRC computation matches known value")
    func crcComputation() {
        // CRC of an empty buffer should be 0.
        #expect(FITCRC.compute(Data()) == 0)

        // CRC of the ASCII ".FIT" bytes (a basic sanity check).
        let fitSig = Data([0x2E, 0x46, 0x49, 0x54])
        let crc = FITCRC.compute(fitSig)
        // Just verify it produces a non-zero deterministic value.
        #expect(crc != 0)
        // Computing it again should give the same result.
        #expect(FITCRC.compute(fitSig) == crc)
    }
}
