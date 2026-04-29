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

    /// One-shot pending continuations: fulfilled once then removed.
    private var pendingContinuations: [UInt16: AsyncStream<GFDIMessage>.Continuation] = [:]

    /// Persistent subscriptions: all messages of the subscribed type are yielded
    /// until `unsubscribe(from:)` is called.  Used for streaming chunk loops.
    private var subscriptions: [UInt16: AsyncStream<GFDIMessage>.Continuation] = [:]

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
        for (_, cont) in subscriptions { cont.finish() }
        subscriptions.removeAll()
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
        // Persistent subscriptions take priority over one-shot continuations.
        if let cont = subscriptions[typeCode] {
            BLELogger.gfdi.debug("← routed to subscription type=0x\(String(format: "%04X", typeCode))")
            cont.yield(message)
        } else if let cont = pendingContinuations.removeValue(forKey: typeCode) {
            BLELogger.gfdi.debug("← routed to pending wait type=0x\(String(format: "%04X", typeCode))")
            cont.yield(message)
            cont.finish()
        } else {
            BLELogger.gfdi.debug("← routed to unsolicited handler type=0x\(String(format: "%04X", typeCode))")
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

    // MARK: - Send-and-wait (atomic, avoids TOCTOU race)

    /// Send `message` and wait for the first inbound message of `awaitType`.
    ///
    /// The response continuation is registered **before** the outbound message
    /// is written to the wire, so a very-fast response cannot slip into the
    /// unsolicited handler between `send` and `waitForMessage`.
    public func sendAndWait(
        _ message: GFDIMessage,
        awaitType: GFDIMessageType,
        timeout: Duration = .seconds(10)
    ) async throws -> GFDIMessage {
        return try await awaitResponse(forType: awaitType.rawValue, timeout: timeout) {
            let wire = message.encode()
            BLELogger.gfdi.debug("→ GFDI type=0x\(String(format: "%04X", message.type.rawValue)) wireLen=\(wire.count)")
            try await self.transport.sendGFDI(wire)
        }
    }

    // MARK: - Persistent subscriptions (for streaming chunk loops)

    /// Register a persistent subscription for `type`.  Every inbound message of
    /// that type is yielded to the returned `AsyncStream` until `unsubscribe` is
    /// called or `stopReceiving` tears everything down.
    ///
    /// Only one subscription per type is supported.  Calling `subscribe` again
    /// for the same type replaces the previous one (finishing the old stream).
    public func subscribe(to type: GFDIMessageType) -> AsyncStream<GFDIMessage> {
        let (stream, cont) = AsyncStream<GFDIMessage>.makeStream()
        if subscriptions[type.rawValue] != nil {
            BLELogger.gfdi.debug("subscribe: replacing existing subscription for type=0x\(String(format: "%04X", type.rawValue))")
            subscriptions[type.rawValue]?.finish()
        } else {
            BLELogger.gfdi.debug("subscribe: registered for type=0x\(String(format: "%04X", type.rawValue))")
        }
        subscriptions[type.rawValue] = cont
        return stream
    }

    /// Cancel the subscription for `type` and finish its stream.
    public func unsubscribe(from type: GFDIMessageType) {
        if subscriptions[type.rawValue] != nil {
            BLELogger.gfdi.debug("unsubscribe: type=0x\(String(format: "%04X", type.rawValue))")
        }
        subscriptions.removeValue(forKey: type.rawValue)?.finish()
    }
}
