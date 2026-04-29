import Foundation
import os

/// Top-level Garmin BLE orchestrator.
///
/// Stack (bottom to top):
/// 1. `BluetoothCentral` — raw GATT scan / connect / read / write / notify.
/// 2. `MultiLinkTransport` — V2 ML protocol: CLOSE_ALL_REQ, REGISTER_ML_REQ for
///    GFDI service, handle prefix tagging, COBS encoding/decoding.
/// 3. `GFDIClient` — `GFDIMessage` send/receive over the GFDI handle.
/// 4. `GarminDeviceManager` (this) — runs the device-initiated handshake.
///
/// Pairing handshake:
/// 1. BLE connect + service & characteristic discovery + subscribe to notify.
/// 2. ML init: CLOSE_ALL → wait CLOSE_ALL_RESP → REGISTER_ML(GFDI) → handle.
/// 3. Watch sends DEVICE_INFORMATION → host replies with RESPONSE (incl. host info).
/// 4. Watch sends CONFIGURATION → host ACKs and sends own CONFIGURATION.
/// 5. Optional AUTH_NEGOTIATION → host ACKs with GUESS_OK.
/// 6. Host sends SYSTEM_EVENTs (SYNC_READY / PAIR_COMPLETE / SYNC_COMPLETE / SETUP_WIZARD_COMPLETE).
public actor GarminDeviceManager: DeviceManagerProtocol {

    private let central: BluetoothCentral
    private let transport: MultiLinkTransport
    private let gfdiClient: GFDIClient

    private var _isConnected: Bool = false
    private var _connectedDevice: PairedDevice?

    public init() {
        let central = BluetoothCentral()
        let transport = MultiLinkTransport(central: central)
        self.central = central
        self.transport = transport
        self.gfdiClient = GFDIClient(transport: transport)
    }

    // MARK: - Discovery

    public nonisolated func discover() -> AsyncStream<DiscoveredDevice> {
        BLELogger.transport.info("Starting device discovery")
        return AsyncStream { continuation in
            let task = Task {
                let stream = await central.scanForDevices()
                for await device in stream {
                    continuation.yield(device)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public func stopDiscovery() async {
        BLELogger.transport.info("Stopping device discovery")
        await central.stopScanning()
    }

    // MARK: - Pairing

    public func pair(_ device: DiscoveredDevice) async throws -> PairedDevice {
        BLELogger.auth.info("Pairing with: \(device.name) (\(device.identifier))")

        try await central.connect(identifier: device.identifier)
        try await central.discoverServices()

        let mtu = await central.negotiatedMTU
        await transport.setMaxWriteSize(mtu)
        BLELogger.auth.debug("Negotiated MTU: \(mtu)")

        do {
            // ML protocol setup: CLOSE_ALL + REGISTER_ML(GFDI) → handle.
            try await transport.initializeGFDI(timeout: .seconds(10))

            // Now start GFDI receive loop and run the device-initiated handshake.
            await gfdiClient.startReceiving()

            // Handle async messages from the watch (AUTH_NEGOTIATION, etc.)
            // that arrive outside our request/response wait points.
            let client = gfdiClient
            await gfdiClient.setUnsolicitedHandler { msg in
                Task { await Self.handleUnsolicited(msg, via: client) }
            }

            let info = try await runHandshake()

            _isConnected = true
            let paired = PairedDevice(
                identifier: device.identifier,
                name: info.deviceName.isEmpty ? device.name : info.deviceName,
                model: info.deviceModel.isEmpty ? nil : info.deviceModel
            )
            _connectedDevice = paired
            BLELogger.auth.info("Pairing complete: \(paired.name)")
            return paired
        } catch {
            BLELogger.auth.error("Pairing failed: \(error.localizedDescription)")
            await gfdiClient.stopReceiving()
            await transport.shutdown()
            await central.disconnect()
            throw error
        }
    }

    /// Asynchronous handler for messages that arrive outside an explicit
    /// `waitForMessage`. After the initial handshake the watch sends a
    /// stream of post-pair onboarding requests (CURRENT_TIME_REQUEST,
    /// MUSIC_CONTROL_CAPABILITIES, PROTOBUF_REQUEST, SYNCHRONIZATION,
    /// WEATHER_REQUEST, etc.) and **stays in pair-UI until they get
    /// answered** — the watch retransmits each request roughly every 1s
    /// until it gets an ACK. We must at minimum reply with a bare 9-byte
    /// ACK to every non-RESPONSE message; for `CURRENT_TIME_REQUEST` we
    /// have to send the actual time so the watch can set its clock and
    /// finish the setup wizard.
    private static func handleUnsolicited(_ msg: GFDIMessage, via client: GFDIClient) async {
        switch msg.type {
        case .authNegotiation:
            if let auth = try? AuthNegotiationMessage.decode(from: msg.payload) {
                BLELogger.auth.info("AUTH_NEGOTIATION (async): unk=\(auth.unknown) flags=\(auth.authFlags)")
                let ack = AuthNegotiationStatusResponse(echoing: auth, status: .guessOk)
                try? await client.send(message: ack.toMessage())
            }
        case .response:
            // ACKs from the watch — informational, no action needed.
            BLELogger.gfdi.debug("Unsolicited RESPONSE")
        case .currentTimeRequest:
            await respondToCurrentTimeRequest(msg, via: client)
        default:
            // Bare ACK for everything else — without this the watch
            // assumes the host is unresponsive and stays in setup-wizard.
            BLELogger.gfdi.debug("ACKing unsolicited 0x\(String(format: "%04X", msg.type.rawValue))")
            let ack = GFDIResponse(originalType: msg.type, status: .ack)
            try? await client.send(message: ack.toMessage())
        }
    }

    /// Reply to CURRENT_TIME_REQUEST with the current Garmin-epoch
    /// timestamp + timezone metadata. The watch needs this to set its
    /// clock and exit the post-pair setup wizard.
    /// Format mirrors Gadgetbridge `CurrentTimeRequestMessage.generateOutgoing`.
    private static func respondToCurrentTimeRequest(
        _ msg: GFDIMessage,
        via client: GFDIClient
    ) async {
        // Garmin epoch starts 1989-12-31 00:00:00 UTC; offset from Unix epoch:
        let garminEpochOffset: TimeInterval = 631_065_600
        let now = Date()
        let unixSec = Int32(now.timeIntervalSince1970)
        let garminTs = UInt32(bitPattern: unixSec - Int32(garminEpochOffset))
        let tz = TimeZone.current
        let tzOffsetSec = Int32(tz.secondsFromGMT(for: now))

        // Parse the inbound 4-byte referenceID (echoed back to the watch).
        var reader = ByteReader(data: msg.payload)
        let refID: UInt32 = (try? reader.readUInt32LE()) ?? 0

        var extra = Data()
        extra.appendUInt32LE(refID)
        extra.appendUInt32LE(garminTs)
        extra.appendUInt32LE(UInt32(bitPattern: tzOffsetSec))
        extra.appendUInt32LE(0) // nextTransitionEnds (we don't compute DST)
        extra.appendUInt32LE(0) // nextTransitionStarts

        BLELogger.gfdi.info("CURRENT_TIME_REQUEST refID=\(refID) — replying ts=\(garminTs) tz=\(tzOffsetSec)s")
        let response = GFDIResponse(
            originalType: .currentTimeRequest,
            status: .ack,
            additionalPayload: extra
        )
        try? await client.send(message: response.toMessage())
    }

    /// The device-initiated GFDI handshake (after ML init has assigned a handle).
    ///
    /// Per `docs/gadgetbridge-instinct-pairing.md` §10 — the watch initiates,
    /// host replies with a **bare 9-byte ACK** for DEVICE_INFORMATION (no
    /// host-info echo!), then ACK + own CONFIGURATION for CONFIGURATION,
    /// then SYSTEM_EVENT bursts.
    private func runHandshake() async throws -> DeviceInformationMessage {
        BLELogger.auth.debug("Handshake: waiting for DEVICE_INFORMATION")
        let devInfoMsg = try await gfdiClient.waitForMessage(type: .deviceInformation, timeout: .seconds(15))
        let devInfo = try DeviceInformationMessage.decode(from: devInfoMsg.payload)
        BLELogger.auth.info(
            "Device: \(devInfo.deviceName) model=\(devInfo.deviceModel) sw=\(devInfo.softwareVersion) maxPkt=\(devInfo.maxPacketSize)"
        )

        // Bare 9-byte ACK — Gadgetbridge does NOT send a host DEVICE_INFORMATION echo.
        let devInfoAck = GFDIResponse(originalType: .deviceInformation, status: .ack)
        try await gfdiClient.send(message: devInfoAck.toMessage())

        BLELogger.auth.debug("Handshake: waiting for CONFIGURATION")
        let configMsg = try await gfdiClient.waitForMessage(type: .configuration, timeout: .seconds(15))
        let watchConfig = try ConfigurationMessage.decode(from: configMsg.payload)
        BLELogger.auth.info("Watch capabilities: \(watchConfig.capabilityBytes.count) bytes")

        // ACK the watch's CONFIGURATION, then echo our own.
        let configAck = GFDIResponse(originalType: .configuration, status: .ack)
        try await gfdiClient.send(message: configAck.toMessage())

        let ourConfig = ConfigurationMessage.ourCapabilities()
        try await gfdiClient.send(message: ourConfig.toMessage())

        // **Do not wait for AUTH_NEGOTIATION here.** Gadgetbridge calls
        // `completeInitialization()` immediately after parsing CONFIGURATION
        // and starts sending the post-init burst with no idle gap. If the
        // watch ever sends AUTH_NEGOTIATION, it arrives asynchronously and
        // is handled via the unsolicited handler (set up below).
        //
        // The Instinct Solar 1 was observed to disconnect during a 3-second
        // idle wait after our CONFIGURATION echo — its session timeout is
        // shorter than that. See `docs/gadgetbridge-instinct-pairing.md`.

        // Post-init burst (matches Gadgetbridge `completeInitialization()`,
        // see `docs/gadgetbridge-instinct-pairing.md` §10 step 10):
        //   1. SUPPORTED_FILE_TYPES_REQUEST — required; the watch's state
        //      machine waits for this after CONFIGURATION before accepting
        //      SYSTEM_EVENTs. Sending SYNC_READY before this caused the
        //      watch to disconnect cleanly.
        //   2. DEVICE_SETTINGS — auto-upload + weather toggles.
        //   3. SYNC_READY → PAIR_COMPLETE → SYNC_COMPLETE → SETUP_WIZARD_COMPLETE.
        //
        // We skip `TIME_UPDATED` for now: Gadgetbridge sends it with a 4-byte
        // Garmin-epoch timestamp (`javaMillisToGarminTimestamp(...)`) when the
        // `syncTime` pref is enabled. It is optional, and the value field is
        // a different size from the lifecycle events.
        BLELogger.auth.debug("Sending SUPPORTED_FILE_TYPES_REQUEST")
        try await gfdiClient.send(message: SupportedFileTypesRequestMessage().toMessage())

        BLELogger.auth.debug("Sending DEVICE_SETTINGS")
        try await gfdiClient.send(message: SetDeviceSettingsMessage.defaults().toMessage())

        BLELogger.auth.debug("Sending SYNC_READY / PAIR_COMPLETE / SYNC_COMPLETE / SETUP_WIZARD_COMPLETE")
        try await gfdiClient.send(message: SystemEventMessage(eventType: .syncReady).toMessage())
        try await gfdiClient.send(message: SystemEventMessage(eventType: .pairComplete).toMessage())
        try await gfdiClient.send(message: SystemEventMessage(eventType: .syncComplete).toMessage())
        try await gfdiClient.send(message: SystemEventMessage(eventType: .setupWizardComplete).toMessage())

        return devInfo
    }

    // MARK: - Connection

    public func connect(_ device: PairedDevice) async throws {
        BLELogger.transport.info("Connecting to paired device: \(device.name)")

        try await central.connect(identifier: device.identifier)
        try await central.discoverServices()

        let mtu = await central.negotiatedMTU
        await transport.setMaxWriteSize(mtu)

        try await transport.initializeGFDI(timeout: .seconds(10))
        await gfdiClient.startReceiving()

        _ = try await runHandshake()
        _isConnected = true
        _connectedDevice = device
        BLELogger.transport.info("Reconnected to: \(device.name)")
    }

    public func disconnect() async {
        BLELogger.transport.info("Disconnecting")
        await gfdiClient.stopReceiving()
        await transport.shutdown()
        await central.disconnect()
        _isConnected = false
        _connectedDevice = nil
    }

    // MARK: - File Sync (not yet implemented)

    public func pullFITFiles(
        directories: Set<FITDirectory>,
        progress: AsyncStream<SyncProgress>.Continuation?
    ) async throws -> [URL] {
        progress?.yield(.failed(PairingError.authenticationFailed("File sync not implemented yet")))
        throw PairingError.authenticationFailed("File sync not implemented yet")
    }

    public func uploadCourse(_ url: URL) async throws {
        throw PairingError.authenticationFailed("Course upload not implemented yet")
    }

    // MARK: - Properties

    public var isConnected: Bool { _isConnected }
    public var connectedDevice: PairedDevice? { _connectedDevice }
}
