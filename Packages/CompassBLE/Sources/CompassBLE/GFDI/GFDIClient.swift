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

    /// One-shot waits specifically for `RESPONSE` (0x1388) messages, keyed by
    /// the response's `originalType` (the request that's being ACKed). The
    /// generic `pendingContinuations[0x1388]` would happily route any response
    /// to any waiter — that race meant a concurrent weather `FIT_DEFINITION`
    /// ACK (originalType=0x1393) could satisfy a pending `DownloadRequest`
    /// (expecting originalType=0x138A) and the download handler would
    /// mis-decode the wrong payload. Keying on originalType lets multiple
    /// in-flight requests await their specific ACKs without stealing each
    /// other's. See `docs/issues/sync_errors.md`.
    private var pendingResponses: [UInt16: AsyncStream<GFDIMessage>.Continuation] = [:]

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
        for (_, cont) in pendingResponses { cont.finish() }
        pendingResponses.removeAll()
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
            return
        }
        // RESPONSEs (0x1388) carry the originalType in payload[0..<2] LE. Try
        // to match an originalType-specific waiter first so concurrent in-flight
        // requests don't steal each other's ACKs.
        if message.type == .response, message.payload.count >= 2 {
            let originalType = UInt16(message.payload[message.payload.startIndex]) |
                              (UInt16(message.payload[message.payload.startIndex + 1]) << 8)
            if let cont = pendingResponses.removeValue(forKey: originalType) {
                BLELogger.gfdi.debug("← routed to pending response originalType=0x\(String(format: "%04X", originalType))")
                cont.yield(message)
                cont.finish()
                return
            }
        }
        if let cont = pendingContinuations.removeValue(forKey: typeCode) {
            BLELogger.gfdi.debug("← routed to pending wait type=0x\(String(format: "%04X", typeCode))")
            cont.yield(message)
            cont.finish()
            return
        }
        BLELogger.gfdi.debug("← routed to unsolicited handler type=0x\(String(format: "%04X", typeCode))")
        unsolicitedHandler?(message)
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

    /// Wait for a `RESPONSE` (0x1388) whose `originalType` matches
    /// `originalType`. Distinct from `awaitResponse(forType:)` so two callers
    /// awaiting different request ACKs concurrently don't collide.
    private func awaitResponseTo(
        originalType: UInt16,
        timeout: Duration,
        beforeWait: @Sendable () async throws -> Void
    ) async throws -> GFDIMessage {
        let (stream, continuation) = AsyncStream<GFDIMessage>.makeStream()
        pendingResponses[originalType] = continuation

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
            self.pendingResponses.removeValue(forKey: originalType)
            return result
        }
    }

    // MARK: - Send-and-wait (atomic, avoids TOCTOU race)

    /// Send `message` and wait for the first inbound message of `awaitType`.
    ///
    /// The response continuation is registered **before** the outbound message
    /// is written to the wire, so a very-fast response cannot slip into the
    /// unsolicited handler between `send` and `waitForMessage`.
    ///
    /// When `awaitType == .response`, the wait additionally filters by the
    /// outgoing message's `type.rawValue` as the expected `originalType` —
    /// every caller of `sendAndWait(.response)` is asking for the ACK of the
    /// request they just sent, so this is what they want, and it prevents an
    /// unrelated 0x1388 ACK (for a concurrent send) from satisfying the wait.
    public func sendAndWait(
        _ message: GFDIMessage,
        awaitType: GFDIMessageType,
        timeout: Duration = .seconds(10)
    ) async throws -> GFDIMessage {
        let send: @Sendable () async throws -> Void = {
            let wire = message.encode()
            BLELogger.gfdi.debug("→ GFDI type=0x\(String(format: "%04X", message.type.rawValue)) wireLen=\(wire.count)")
            try await self.transport.sendGFDI(wire)
        }
        if awaitType == .response {
            return try await awaitResponseTo(
                originalType: message.type.rawValue,
                timeout: timeout,
                beforeWait: send
            )
        }
        return try await awaitResponse(forType: awaitType.rawValue, timeout: timeout, beforeWait: send)
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
