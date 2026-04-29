import Testing
import Foundation
@testable import CompassBLE

/// Tests for GFDI frame reassembly.
@Suite("FrameAssembler Tests")
struct FrameAssemblerTests {

    @Test("Single fragment containing complete message")
    func singleFragment() async throws {
        let assembler = FrameAssembler()

        let msg = GFDIMessage(type: .deviceInformation, payload: Data())
        let wireData = msg.encode()

        let result = try await assembler.feed(data: wireData, handle: 1)

        #expect(result != nil)
        #expect(result?.type == .deviceInformation)
        #expect(result?.payload.isEmpty == true)
    }

    @Test("Two fragments assembling one message")
    func twoFragments() async throws {
        let assembler = FrameAssembler()

        let msg = GFDIMessage(type: .systemEvent, payload: Data([0x04, 0x00, 0x00, 0x00, 0x00]))
        let wireData = msg.encode()

        let midpoint = wireData.count / 2
        let frag1 = Data(wireData[0..<midpoint])
        let frag2 = Data(wireData[midpoint...])

        let result1 = try await assembler.feed(data: frag1, handle: 1)
        #expect(result1 == nil)

        let result2 = try await assembler.feed(data: frag2, handle: 1)
        #expect(result2 != nil)
        #expect(result2?.type == .systemEvent)
        #expect(result2?.payload == Data([0x04, 0x00, 0x00, 0x00, 0x00]))
    }

    @Test("Three fragments assembling one message")
    func threeFragments() async throws {
        let assembler = FrameAssembler()

        let payload = Data((0..<20).map { UInt8($0) })
        let msg = GFDIMessage(type: .fileTransferData, payload: payload)
        let wireData = msg.encode()

        let third = wireData.count / 3
        let frag1 = Data(wireData[0..<third])
        let frag2 = Data(wireData[third..<(2 * third)])
        let frag3 = Data(wireData[(2 * third)...])

        let r1 = try await assembler.feed(data: frag1, handle: 1)
        #expect(r1 == nil)

        let r2 = try await assembler.feed(data: frag2, handle: 1)
        #expect(r2 == nil)

        let r3 = try await assembler.feed(data: frag3, handle: 1)
        #expect(r3 != nil)
        #expect(r3?.type == .fileTransferData)
        #expect(r3?.payload == payload)
    }

    @Test("Independent handles do not interfere")
    func independentHandles() async throws {
        let assembler = FrameAssembler()

        let msg1 = GFDIMessage(type: .deviceInformation, payload: Data())
        let wire1 = msg1.encode()

        let msg2 = GFDIMessage(type: .configuration, payload: Data([0x01, 0xFF]))
        let wire2 = msg2.encode()

        let mid1 = wire1.count / 2
        let r1a = try await assembler.feed(data: Data(wire1[0..<mid1]), handle: 1)
        #expect(r1a == nil)

        let r2 = try await assembler.feed(data: wire2, handle: 2)
        #expect(r2 != nil)
        #expect(r2?.type == .configuration)

        let r1b = try await assembler.feed(data: Data(wire1[mid1...]), handle: 1)
        #expect(r1b != nil)
        #expect(r1b?.type == .deviceInformation)
    }

    @Test("Empty data returns nil")
    func emptyData() async throws {
        let assembler = FrameAssembler()
        let result = try await assembler.feed(data: Data(), handle: 0)
        #expect(result == nil)
    }

    @Test("Reset clears buffer")
    func resetClears() async throws {
        let assembler = FrameAssembler()

        let msg = GFDIMessage(type: .authNegotiation, payload: Data([0x01, 0x00, 0x00, 0x00, 0x00]))
        let wireData = msg.encode()

        let mid = wireData.count / 2
        let r1 = try await assembler.feed(data: Data(wireData[0..<mid]), handle: 1)
        #expect(r1 == nil)

        await assembler.reset(handle: 1)

        let r2 = try await assembler.feed(data: wireData, handle: 1)
        #expect(r2 != nil)
        #expect(r2?.type == .authNegotiation)
    }

    @Test("Reset all clears all handles")
    func resetAllClears() async throws {
        let assembler = FrameAssembler()

        let msg = GFDIMessage(type: .deviceInformation, payload: Data())
        let wireData = msg.encode()
        let mid = wireData.count / 2

        _ = try await assembler.feed(data: Data(wireData[0..<mid]), handle: 1)
        _ = try await assembler.feed(data: Data(wireData[0..<mid]), handle: 2)

        await assembler.resetAll()

        let r1 = try await assembler.feed(data: wireData, handle: 1)
        #expect(r1 != nil)

        let r2 = try await assembler.feed(data: wireData, handle: 2)
        #expect(r2 != nil)
    }
}
