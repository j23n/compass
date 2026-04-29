import Foundation
import os

/// Garmin V2 Multi-Link transport.
///
/// Runs **above** `BluetoothCentral` (raw BLE) and **below** `GFDIClient`.
///
/// Responsibilities:
/// - Send `CLOSE_ALL_REQ` on connect to reset any prior session state.
/// - Send `REGISTER_ML_REQ` to allocate a handle for the GFDI service; wait
///   for the device's `REGISTER_ML_RESP` to learn that handle.
/// - Tag every outgoing GFDI fragment with the GFDI handle byte.
/// - Route incoming notifications by their first byte (handle):
///     - `0x00` → management messages (handled here)
///     - GFDI handle → COBS-decode (after stripping handle) and yield
///       the decoded GFDI message bytes to the consumer stream
///
/// Reference: Gadgetbridge `CommunicatorV2.java`
public actor MultiLinkTransport {

    /// Gadgetbridge uses `2L`; we follow the same convention so the watch
    /// recognises the request format.
    private static let clientID: UInt64 = 2

    /// GFDI service code in the V2 ML registry.
    private static let gfdiServiceCode: UInt16 = 1

    /// Multi-Link request type ordinals (from Gadgetbridge `RequestType` enum).
    private enum RequestType: UInt8 {
        case registerMLRequest   = 0
        case registerMLResponse  = 1
        case closeHandleRequest  = 2
        case closeHandleResponse = 3
        case unkHandle           = 4
        case closeAllRequest     = 5
        case closeAllResponse    = 6
        case unkRequest          = 7
        case unkResponse         = 8
    }

    public enum MLError: Error, Sendable {
        case registrationFailed(status: UInt8)
        case unexpectedResponse
        case timeout
    }

    // MARK: - Dependencies

    private let central: BluetoothCentral

    // MARK: - State

    private var gfdiHandle: UInt8?
    private let decoder = CobsCodec.Decoder()

    /// Per-message send lock. Without this, a multi-fragment GFDI message
    /// can be split across the BLE wire by another `sendGFDI` invocation
    /// (e.g. an unsolicited-message ACK firing concurrently with the
    /// post-pair burst), leaving the watch unable to reassemble either
    /// message. The lock guarantees all fragments of a given GFDI message
    /// reach `BluetoothCentral.write()` contiguously.
    private var sendInFlight = false
    private var sendWaiters: [CheckedContinuation<Void, Never>] = []

    private var gfdiContinuation: AsyncStream<Data>.Continuation?

    /// One outcome value per registration: either a handle or an error.
    private enum RegisterOutcome: Sendable {
        case handle(UInt8)
        case failure(MLError)
    }

    /// AsyncStream-based response continuations (yield-once).
    private var closeAllContinuation: AsyncStream<Void>.Continuation?
    private var registerContinuation: AsyncStream<RegisterOutcome>.Continuation?

    private var pumpTask: Task<Void, Never>?
    private var maxWriteSize: Int = 20

    // MARK: - Init

    public init(central: BluetoothCentral) {
        self.central = central
    }

    public func setMaxWriteSize(_ size: Int) {
        // Cap at 20 bytes (default BLE ATT_MTU - 3 byte header). iOS may
        // report `maximumWriteValueLength == 512` because the ATT MTU
        // exchange agreed on 512, but older Garmin firmware (Instinct
        // Solar 1) doesn't reliably handle ATT writes that span multiple
        // LL packets — sending a 26-byte write hangs forever waiting for
        // an ATT Write Response that never comes. The watch itself
        // chunks its outbound notifications at 20 bytes, so we mirror
        // that. See `docs/gadgetbridge-instinct-pairing.md`.
        self.maxWriteSize = max(20, min(size, 20))
    }

    // MARK: - Public API

    public func gfdiStream() -> AsyncStream<Data> {
        AsyncStream { continuation in
            self.gfdiContinuation = continuation
        }
    }

    public func initializeGFDI(timeout: Duration = .seconds(10)) async throws {
        startPump()
        BLELogger.transport.info("ML: sending CLOSE_ALL_REQ")
        try await sendCloseAll(timeout: timeout)
        BLELogger.transport.info("ML: sending REGISTER_ML_REQ for GFDI")
        let handle = try await sendRegister(serviceCode: Self.gfdiServiceCode, timeout: timeout)
        gfdiHandle = handle
        BLELogger.transport.info("ML: GFDI registered on handle 0x\(String(format: "%02X", handle))")
    }

    public func sendGFDI(_ gfdiBytes: Data) async throws {
        guard let handle = gfdiHandle else { throw MLError.unexpectedResponse }

        // Acquire the per-message send lock. If another `sendGFDI` is in
        // flight, queue up and wait. Without this, our fragment loop could
        // be preempted by a concurrent caller and the watch would receive
        // interleaved fragments of two different GFDI messages.
        while sendInFlight {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                sendWaiters.append(cont)
            }
        }
        sendInFlight = true

        let cobs = CobsCodec.encode(gfdiBytes)
        let chunkSize = maxWriteSize - 1
        var pos = 0
        do {
            while pos < cobs.count {
                let end = min(pos + chunkSize, cobs.count)
                var frame = Data(capacity: 1 + (end - pos))
                frame.append(handle)
                frame.append(cobs[pos..<end])
                try await central.write(data: frame)
                pos = end
            }
        } catch {
            releaseSendLock()
            throw error
        }
        releaseSendLock()
    }

    /// Wake the next waiter (if any) and clear the send-in-flight flag.
    private func releaseSendLock() {
        sendInFlight = false
        if let next = sendWaiters.first {
            sendWaiters.removeFirst()
            next.resume()
        }
    }

    /// Asynchronous teardown that explicitly releases the GFDI handle on
    /// the watch before disconnecting. The Instinct Solar's firmware
    /// retains registered services across BLE sessions if the host just
    /// drops the link — eventually its handle pool saturates and new
    /// `REGISTER_ML_REQ` calls return `status=2` (failed). Sending
    /// `CLOSE_HANDLE_REQ` mirrors Gadgetbridge's `closeService()` and
    /// keeps the watch's allocator clean.
    public func gracefulShutdown() async {
        if let handle = gfdiHandle {
            BLELogger.transport.info("ML: sending CLOSE_HANDLE_REQ for GFDI handle=0x\(String(format: "%02X", handle))")
            var bytes = buildManagementHeader(type: .closeHandleRequest)
            bytes.appendUInt16LE(Self.gfdiServiceCode)
            bytes.append(handle)
            // Best-effort write — if the link is already gone we just
            // proceed to teardown; the watch will GC the handle on
            // BLE-supervision-timeout in that case.
            try? await central.write(data: bytes)
        }
        shutdown()
    }

    public func shutdown() {
        pumpTask?.cancel()
        pumpTask = nil
        gfdiContinuation?.finish()
        gfdiContinuation = nil
        closeAllContinuation?.finish()
        closeAllContinuation = nil
        registerContinuation?.finish()
        registerContinuation = nil
        decoder.reset()
        gfdiHandle = nil

        // Wake any tasks blocked on the send lock so they can fail out
        // cleanly rather than hang waiting for a session that's gone.
        let waiters = sendWaiters
        sendWaiters.removeAll()
        sendInFlight = false
        for c in waiters { c.resume() }
    }

    // MARK: - Internal: pump

    private func startPump() {
        pumpTask?.cancel()
        pumpTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.central.notifications()
            for await raw in stream {
                guard !Task.isCancelled else { break }
                await self.handleNotification(raw)
            }
        }
    }

    private func handleNotification(_ raw: Data) {
        guard !raw.isEmpty else { return }
        let handle = raw[raw.startIndex]
        let body = raw.count > 1 ? Data(raw[(raw.startIndex + 1)...]) : Data()

        if handle == 0 {
            handleManagement(body)
            return
        }

        if let gfdi = gfdiHandle, handle == gfdi {
            decoder.receivedBytes(body)
            while let msg = decoder.retrieveMessage() {
                BLELogger.transport.debug("ML: GFDI message reassembled (\(msg.count) bytes)")
                gfdiContinuation?.yield(msg)
            }
            return
        }

        BLELogger.transport.debug("ML: notification on unknown handle 0x\(String(format: "%02X", handle)) — ignoring")
    }

    // MARK: - Internal: management

    private func handleManagement(_ body: Data) {
        var reader = ByteReader(data: body)
        do {
            let typeByte = try reader.readUInt8()
            let clientID = try reader.readUInt64LE()
            guard clientID == Self.clientID else {
                BLELogger.transport.warning("ML: ignoring mgmt msg with foreign clientID \(clientID)")
                return
            }
            guard let type = RequestType(rawValue: typeByte) else {
                BLELogger.transport.error("ML: unknown mgmt request type 0x\(String(format: "%02X", typeByte))")
                return
            }
            switch type {
            case .closeAllResponse:
                BLELogger.transport.debug("ML: CLOSE_ALL_RESP received")
                closeAllContinuation?.yield(())
                closeAllContinuation?.finish()
                closeAllContinuation = nil
            case .registerMLResponse:
                let serviceCode = try reader.readUInt16LE()
                let status = try reader.readUInt8()
                if status != 0 {
                    BLELogger.transport.error("ML: REGISTER_ML_RESP service=\(serviceCode) status=\(status)")
                    registerContinuation?.yield(.failure(.registrationFailed(status: status)))
                    registerContinuation?.finish()
                    registerContinuation = nil
                    return
                }
                let handle = try reader.readUInt8()
                let reliable = reader.remaining > 0 ? (try? reader.readUInt8()) ?? 0 : 0
                BLELogger.transport.debug("ML: REGISTER_ML_RESP service=\(serviceCode) handle=0x\(String(format: "%02X", handle)) reliable=\(reliable)")
                registerContinuation?.yield(.handle(handle))
                registerContinuation?.finish()
                registerContinuation = nil
            default:
                BLELogger.transport.debug("ML: unhandled mgmt type \(String(describing: type))")
            }
        } catch {
            BLELogger.transport.error("ML: mgmt parse error: \(error)")
        }
    }

    // MARK: - Internal: control message senders

    private func sendCloseAll(timeout: Duration) async throws {
        var bytes = buildManagementHeader(type: .closeAllRequest)
        bytes.append(0x00)
        bytes.append(0x00)
        let payload = bytes

        let (stream, cont) = AsyncStream<Void>.makeStream()
        closeAllContinuation = cont

        try await central.write(data: payload)

        let received = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in stream { return true }
                return false
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return false
            }
            guard let result = try await group.next() else { return false }
            group.cancelAll()
            return result
        }
        closeAllContinuation = nil
        guard received else { throw MLError.timeout }
    }

    private func sendRegister(serviceCode: UInt16, timeout: Duration) async throws -> UInt8 {
        var bytes = buildManagementHeader(type: .registerMLRequest)
        bytes.appendUInt16LE(serviceCode)
        bytes.append(0x00) // reliable=0 (basic ML)
        let payload = bytes

        let (stream, cont) = AsyncStream<RegisterOutcome>.makeStream()
        registerContinuation = cont

        try await central.write(data: payload)

        let outcome: RegisterOutcome = try await withThrowingTaskGroup(of: RegisterOutcome.self) { group in
            group.addTask {
                for await o in stream { return o }
                return .failure(.timeout)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return .failure(.timeout)
            }
            guard let first = try await group.next() else { return .failure(.timeout) }
            group.cancelAll()
            return first
        }
        registerContinuation = nil

        switch outcome {
        case .handle(let h): return h
        case .failure(let e): throw e
        }
    }

    /// Build the 10-byte management header: `[0x00 handle][type:1][clientID:8 LE]`.
    private func buildManagementHeader(type: RequestType) -> Data {
        var data = Data(capacity: 10)
        data.append(0x00)
        data.append(type.rawValue)
        data.appendUInt64LE(Self.clientID)
        return data
    }
}

// MARK: - Helpers

extension Data {
    /// Append a UInt64 in little-endian byte order.
    mutating func appendUInt64LE(_ value: UInt64) {
        for i in 0..<8 {
            append(UInt8((value >> (8 * i)) & 0xFF))
        }
    }
}

extension ByteReader {
    /// Read a little-endian UInt64 and advance the cursor by 8.
    mutating func readUInt64LE() throws -> UInt64 {
        var result: UInt64 = 0
        for i in 0..<8 {
            let byte = UInt64(try readUInt8())
            result |= byte << (8 * i)
        }
        return result
    }
}
