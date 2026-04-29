import Testing
import Foundation
@testable import CompassBLE

/// Tests for MLR (Multi-Link Reliable) transport framing.
///
/// Tests verify the 2-byte header encoding/decoding and round-trip integrity.
@Suite("MLRTransport Tests")
struct MLRTransportTests {

    @Test("Encode produces correct header structure")
    func encodeBasic() async throws {
        let transport = MLRTransport()

        let payload = Data([0xAA, 0xBB, 0xCC])
        let frame = await transport.encode(payload: payload, handle: 1)

        // Frame should be 2 header bytes + 3 payload bytes = 5 bytes
        #expect(frame.count == 5)

        // Byte 0: 0x80 | (handle=1 << 4) | (reqNum=0 >> 2)
        // = 0x80 | 0x10 | 0x00 = 0x90
        #expect(frame[0] == 0x90)

        // Byte 1: (reqNum=0 << 6) | seqNum=0
        // = 0x00 | 0x00 = 0x00
        #expect(frame[1] == 0x00)

        // Payload preserved
        #expect(Data(frame[2...]) == payload)
    }

    @Test("Encode increments sequence number")
    func encodeSequenceIncrement() async throws {
        let transport = MLRTransport()
        let handle: UInt8 = 2

        let frame1 = await transport.encode(payload: Data([0x01]), handle: handle)
        let frame2 = await transport.encode(payload: Data([0x02]), handle: handle)

        // First frame: seqNum = 0
        // Byte 1: (0 << 6) | 0 = 0x00
        #expect(frame1[1] & 0x3F == 0)

        // Second frame: seqNum = 1
        // Byte 1: (0 << 6) | 1 = 0x01
        #expect(frame2[1] & 0x3F == 1)
    }

    @Test("Decode extracts correct fields")
    func decodeBasic() async throws {
        let transport = MLRTransport()

        // Construct a frame:
        // Byte 0: 0x80 | (handle=3 << 4) | (reqNum=5 >> 2 = 1)
        //       = 0x80 | 0x30 | 0x01 = 0xB1
        // Byte 1: (reqNum=5: low 2 bits = 1 << 6) | seqNum=7
        //       = 0x40 | 0x07 = 0x47
        let data = Data([0xB1, 0x47, 0xDE, 0xAD])

        let decoded = try await transport.decode(data: data)

        #expect(decoded.handle == 3)
        #expect(decoded.seqNum == 7)
        #expect(decoded.reqNum == 5) // (1 << 2) | 1 = 5
        #expect(decoded.payload == Data([0xDE, 0xAD]))
    }

    @Test("Decode rejects data without MLR marker bit")
    func decodeRejectsNoMarker() async {
        let transport = MLRTransport()

        // Byte 0 without 0x80 marker
        let data = Data([0x10, 0x00, 0xFF])

        do {
            _ = try await transport.decode(data: data)
            Issue.record("Should have thrown for missing marker bit")
        } catch is MLRTransport.MLRError {
            // Expected
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }

    @Test("Decode rejects too-short data")
    func decodeRejectsTooShort() async {
        let transport = MLRTransport()

        do {
            _ = try await transport.decode(data: Data([0x80]))
            Issue.record("Should have thrown for too-short data")
        } catch is MLRTransport.MLRError {
            // Expected
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }

    @Test("Encode/decode round-trip preserves payload")
    func roundTrip() async throws {
        let transport = MLRTransport()
        let handle: UInt8 = 1
        let payload = Data([0x01, 0x02, 0x03, 0x04, 0x05])

        let frame = await transport.encode(payload: payload, handle: handle)
        let decoded = try await transport.decode(data: frame)

        #expect(decoded.handle == handle)
        #expect(decoded.payload == payload)
        #expect(decoded.seqNum == 0) // First frame on this handle
    }

    @Test("Empty payload encode/decode")
    func emptyPayload() async throws {
        let transport = MLRTransport()
        let frame = await transport.encode(payload: Data(), handle: 0)

        // Just the 2-byte header
        #expect(frame.count == 2)

        let decoded = try await transport.decode(data: frame)
        #expect(decoded.payload.isEmpty)
        #expect(decoded.handle == 0)
    }

    @Test("Different handles have independent sequence numbers")
    func independentHandles() async throws {
        let transport = MLRTransport()

        let frame1h1 = await transport.encode(payload: Data([0x01]), handle: 1)
        let frame2h1 = await transport.encode(payload: Data([0x02]), handle: 1)
        let frame1h2 = await transport.encode(payload: Data([0x03]), handle: 2)

        // Handle 1: seq should be 0, 1
        #expect(frame1h1[1] & 0x3F == 0)
        #expect(frame2h1[1] & 0x3F == 1)

        // Handle 2: seq should be 0 (independent)
        #expect(frame1h2[1] & 0x3F == 0)
    }

    @Test("ACK frame has no payload")
    func ackFrame() async throws {
        let transport = MLRTransport()
        let ack = await transport.generateAck(forHandle: 1)
        #expect(ack.count == 2) // Just the header
    }

    @Test("Handle number encoded in correct position")
    func handleEncoding() async throws {
        let transport = MLRTransport()

        for handle: UInt8 in 0...7 {
            let frame = await transport.encode(payload: Data([0xFF]), handle: handle)
            let decoded = try await transport.decode(data: frame)
            #expect(decoded.handle == handle)
        }
    }
}
