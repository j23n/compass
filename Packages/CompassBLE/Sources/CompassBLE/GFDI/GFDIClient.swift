import Foundation
import os

/// Sends and receives GFDI messages over a `MultiLinkTransport`.
///
/// Outgoing path:  GFDI encode → `MultiLinkTransport.sendGFDI` (which COBS-encodes
/// and prefixes the GFDI handle, fragmenting as needed).
///
/// Incoming path:  `MultiLinkTransport` yields fully COBS-decoded GFDI bytes, which
/// we parse into `GFDIMessage` and dispatch to either a pending request continuation
/// or the unsolicited handler.
public actor GFDIClient {

    private let transport: MultiLinkTransport

    private var unsolicitedHandler: ((GFDIMessage) -> Void)?

    private var receiveTask: Task<Void, Never>?

    /// Stream-based pending response handlers (actor-safe).
    private var pendingContinuations: [UInt16: AsyncStream<GFDIMessage>.Continuation] = [:]

    public init(transport: MultiLinkTransport) {
        self.transport = transport
    }

    // MARK: - Lifecycle

    public func startReceiving() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.transport.gfdiStream()
            for await raw in stream {
                guard !Task.isCancelled else { break }
                await self.handleGFDIBytes(raw)
            }
            BLELogger.gfdi.debug("GFDI receive loop ended")
        }
    }

    public func stopReceiving() {
        receiveTask?.cancel()
        receiveTask = nil
        for (_, cont) in pendingContinuations { cont.finish() }
        pendingContinuations.removeAll()
    }

    public func setUnsolicitedHandler(_ handler: @escaping @Sendable (GFDIMessage) -> Void) {
        self.unsolicitedHandler = handler
    }

    // MARK: - Send

    public func send(message: GFDIMessage) async throws {
        let wire = message.encode()
        BLELogger.gfdi.debug("→ GFDI type=0x\(String(format: "%04X", message.type.rawValue)) wireLen=\(wire.count)")
        try await transport.sendGFDI(wire)
    }

    // MARK: - Receive

    private func handleGFDIBytes(_ data: Data) async {
        do {
            let msg = try GFDIMessage.decode(from: data)
            BLELogger.gfdi.info("← GFDI type=0x\(String(format: "%04X", msg.type.rawValue)) payloadLen=\(msg.payload.count)")
            routeMessage(msg)
        } catch {
            BLELogger.gfdi.error("GFDI decode failed: \(error) bytes=\(data.prefix(32).map { String(format: "%02X", $0) }.joined())")
        }
    }

    private func routeMessage(_ message: GFDIMessage) {
        let typeCode = message.type.rawValue
        if let cont = pendingContinuations.removeValue(forKey: typeCode) {
            cont.yield(message)
            cont.finish()
        } else {
            unsolicitedHandler?(message)
        }
    }

    // MARK: - Wait for response

    /// Wait for a specific message type to arrive (without sending anything).
    public func waitForMessage(
        type: GFDIMessageType,
        timeout: Duration = .seconds(15)
    ) async throws -> GFDIMessage {
        return try await awaitResponse(forType: type.rawValue, timeout: timeout, beforeWait: {})
    }

    private func awaitResponse(
        forType typeCode: UInt16,
        timeout: Duration,
        beforeWait: @Sendable () async throws -> Void
    ) async throws -> GFDIMessage {
        let (stream, continuation) = AsyncStream<GFDIMessage>.makeStream()
        pendingContinuations[typeCode] = continuation

        try await beforeWait()

        return try await withThrowingTaskGroup(of: GFDIMessage.self) { group in
            group.addTask {
                for await msg in stream { return msg }
                throw PairingError.connectionTimeout
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw PairingError.connectionTimeout
            }
            guard let result = try await group.next() else { throw PairingError.connectionTimeout }
            group.cancelAll()
            self.pendingContinuations.removeValue(forKey: typeCode)
            return result
        }
    }
}
