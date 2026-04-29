import Testing
import Foundation
@testable import CompassBLE

/// Tests for GFDI message encoding and decoding.
///
/// Wire format: `[length LE 16][type LE 16][payload][CRC16 LE 16]`
/// Length value = total message size (including itself).
@Suite("GFDIMessage Tests")
struct GFDIMessageTests {

    @Test("Encode empty payload message")
    func encodeEmptyPayload() throws {
        let msg = GFDIMessage(type: .deviceInformation, payload: Data())
        let encoded = msg.encode()

        #expect(encoded.count == 6)
        #expect(encoded[0] == 0x06)
        #expect(encoded[1] == 0x00)

        // Type 0x13A0 = [0xA0, 0x13]
        #expect(encoded[2] == 0xA0)
        #expect(encoded[3] == 0x13)

        let crc = UInt16(encoded[4]) | (UInt16(encoded[5]) << 8)
        let expected = CRC16.compute(data: Data([0x06, 0x00, 0xA0, 0x13]))
        #expect(crc == expected)
    }

    @Test("Encode message with payload")
    func encodeWithPayload() throws {
        let payload = Data([0xAA, 0xBB, 0xCC])
        let msg = GFDIMessage(type: .response, payload: payload)
        let encoded = msg.encode()

        #expect(encoded.count == 9)
        #expect(encoded[0] == 0x09)
        #expect(encoded[1] == 0x00)

        // Type 0x1388 = [0x88, 0x13]
        #expect(encoded[2] == 0x88)
        #expect(encoded[3] == 0x13)

        #expect(encoded[4] == 0xAA)
        #expect(encoded[5] == 0xBB)
        #expect(encoded[6] == 0xCC)
    }

    @Test("Decode round-trip preserves message")
    func roundTrip() throws {
        let original = GFDIMessage(type: .systemEvent, payload: Data([0x04, 0x00, 0x00, 0x00, 0x00]))
        let encoded = original.encode()
        let decoded = try GFDIMessage.decode(from: encoded)

        #expect(decoded.type == original.type)
        #expect(decoded.payload == original.payload)
    }

    @Test("Decode empty payload round-trip")
    func roundTripEmptyPayload() throws {
        let original = GFDIMessage(type: .configuration, payload: Data())
        let encoded = original.encode()
        let decoded = try GFDIMessage.decode(from: encoded)

        #expect(decoded.type == original.type)
        #expect(decoded.payload.isEmpty)
    }

    @Test("Decode rejects too-short data")
    func decodeTooShort() {
        #expect(throws: GFDIMessage.DecodeError.self) {
            _ = try GFDIMessage.decode(from: Data([0x01, 0x02]))
        }
    }

    @Test("Decode rejects CRC mismatch")
    func decodeCRCMismatch() {
        let msg = GFDIMessage(type: .deviceInformation, payload: Data())
        var encoded = msg.encode()
        encoded[encoded.count - 1] ^= 0x01

        #expect(throws: GFDIMessage.DecodeError.self) {
            _ = try GFDIMessage.decode(from: encoded)
        }
    }

    @Test("Decode rejects length mismatch")
    func decodeLengthMismatch() {
        let data = Data([0x20, 0x00, 0xA0, 0x13, 0x00, 0x00])

        #expect(throws: GFDIMessage.DecodeError.self) {
            _ = try GFDIMessage.decode(from: data)
        }
    }

    @Test("Message type values match Gadgetbridge GarminMessage")
    func messageTypeValues() {
        #expect(GFDIMessageType.response.rawValue == 0x1388)             // 5000
        #expect(GFDIMessageType.fileTransferData.rawValue == 0x138C)     // 5004
        #expect(GFDIMessageType.deviceInformation.rawValue == 0x13A0)    // 5024
        #expect(GFDIMessageType.systemEvent.rawValue == 0x13A6)          // 5030
        #expect(GFDIMessageType.protobufRequest.rawValue == 0x13B3)      // 5043
        #expect(GFDIMessageType.protobufResponse.rawValue == 0x13B4)     // 5044
        #expect(GFDIMessageType.configuration.rawValue == 0x13BA)        // 5050
        #expect(GFDIMessageType.authNegotiation.rawValue == 0x13ED)      // 5101
    }

    @Test("Compact-encoded type decodes via (raw & 0xFF) + 5000")
    func compactTypeDecoding() throws {
        // Build a message that encodes the type 5024 in compact form (0x80 | 24 = 0x8018).
        // Length = 6 (total). CRC over [0x06, 0x00, 0x18, 0x80].
        var data = Data([0x06, 0x00, 0x18, 0x80])
        let crc = CRC16.compute(data: data)
        data.append(UInt8(crc & 0xFF))
        data.append(UInt8(crc >> 8))

        let decoded = try GFDIMessage.decode(from: data)
        #expect(decoded.type == .deviceInformation)
    }

    @Test("Large payload round-trip")
    func largePayload() throws {
        let payload = Data((0..<500).map { UInt8($0 & 0xFF) })
        let original = GFDIMessage(type: .fileTransferData, payload: payload)
        let encoded = original.encode()
        let decoded = try GFDIMessage.decode(from: encoded)

        #expect(decoded.type == .fileTransferData)
        #expect(decoded.payload == payload)
    }

    @Test("Known wire bytes decode correctly")
    func knownWireBytes() throws {
        let crcInput = Data([0x06, 0x00, 0xA0, 0x13])
        let crc = CRC16.compute(data: crcInput)

        var wireData = crcInput
        wireData.append(UInt8(crc & 0xFF))
        wireData.append(UInt8(crc >> 8))

        let decoded = try GFDIMessage.decode(from: wireData)
        #expect(decoded.type == .deviceInformation)
        #expect(decoded.payload.isEmpty)
    }
}
