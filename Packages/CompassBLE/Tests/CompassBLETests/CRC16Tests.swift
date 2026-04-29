import Testing
import Foundation
@testable import CompassBLE

/// Tests for the Garmin CRC-16 implementation (nibble-based, custom table).
@Suite("CRC16 Tests")
struct CRC16Tests {

    @Test("Empty data returns zero")
    func emptyData() {
        let crc = CRC16.compute(data: Data())
        #expect(crc == 0x0000)
    }

    @Test("Single byte 0x00 returns 0x0000")
    func singleByteZero() {
        let crc = CRC16.compute(data: Data([0x00]))
        #expect(crc == 0x0000)
    }

    @Test("CRC matches a real on-the-wire DEVICE_INFORMATION")
    func realWireBytes() {
        // Bytes captured from a Garmin Instinct Solar's DEVICE_INFORMATION
        // message (length+type+payload, no CRC). The watch's CRC over these
        // bytes is 0xAD67 — verifying our algorithm matches the device.
        let bytes: [UInt8] = [
            0x32, 0x00, 0xA0, 0x13, 0x96, 0x00, 0x8A, 0x0D, 0x83, 0x0C, 0xFE, 0xC7,
            0x76, 0x07, 0x08, 0x02, 0x0E, 0x49, 0x6E, 0x73, 0x74, 0x69, 0x6E, 0x63,
            0x74, 0x20, 0x53, 0x6F, 0x6C, 0x61, 0x72, 0x08, 0x49, 0x6E, 0x73, 0x74,
            0x69, 0x6E, 0x63, 0x74, 0x05, 0x53, 0x6F, 0x6C, 0x61, 0x72, 0x00, 0x00,
        ]
        let crc = CRC16.compute(data: Data(bytes))
        #expect(crc == 0xAD67)
    }

    @Test("CRC differs for different data")
    func differentDataDifferentCRC() {
        let crc1 = CRC16.compute(data: Data([0x01, 0x02]))
        let crc2 = CRC16.compute(data: Data([0x02, 0x01]))
        #expect(crc1 != crc2)
    }

    @Test("CRC is deterministic")
    func deterministic() {
        let data = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let crc1 = CRC16.compute(data: data)
        let crc2 = CRC16.compute(data: data)
        #expect(crc1 == crc2)
    }

    @Test("Large data block produces consistent non-zero CRC")
    func largeDataBlock() {
        let data = Data((0..<1024).map { UInt8($0 & 0xFF) })
        let crc = CRC16.compute(data: data)
        let crc2 = CRC16.compute(data: data)
        #expect(crc == crc2)
        #expect(crc != 0x0000)
    }
}
