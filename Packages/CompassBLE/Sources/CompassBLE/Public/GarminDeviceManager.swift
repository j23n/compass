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
    private var connectionStateContinuation: AsyncStream<ConnectionState>.Continuation?
    private var watchSyncProgressContinuation: AsyncStream<SyncProgress>.Continuation?
    private var watchActivityContinuation: AsyncStream<WatchActivityEvent>.Continuation?

    /// Max GFDI payload size reported by the watch's DEVICE_INFORMATION message.
    /// Defaults to 375 (Instinct Solar 1G value per Gadgetbridge `FileTransferHandler.java:62`).
    private var maxPacketSize: Int = 375

    /// Guards against concurrent syncs (phone-initiated cancels any watch-initiated task).
    private var activeSyncTask: Task<[(url: URL, fileIndex: UInt16)], Error>?

    /// Tracks whether we have completed a full pairing handshake at least once.
    /// Suppresses PAIR_COMPLETE / SETUP_WIZARD_COMPLETE on subsequent reconnects.
    private var hasConnectedOnce: Bool = false

    // MARK: - Service Callbacks (set by the app layer after connect)

    /// Called when the watch sends a WEATHER_REQUEST.  The closure should
    /// return the FIT_DEFINITION + FIT_DATA messages to push, or throw to
    /// silently skip (the watch retries automatically).
    private var weatherProvider: (@Sendable (WeatherRequest) async throws -> [GFDIMessage])?

    /// Called when the watch sends a MUSIC_CONTROL command.  Ordinal maps to
    /// `GarminMusicControlCommand`.
    private var musicCommandHandler: (@Sendable (UInt8) -> Void)?

    /// Called when the watch sends FIND_MY_PHONE_REQUEST or FIND_MY_PHONE_CANCEL.
    private var findMyPhoneHandler: (@Sendable (FindMyPhoneEvent) -> Void)?

    /// Called when a watch-initiated sync completes with (url, fileIndex) pairs.
    private var watchInitiatedSyncHandler: (@Sendable ([(url: URL, fileIndex: UInt16)]) async -> Void)?

    /// Prevents overlapping WeatherKit fetches when the watch retransmits every 5 s.
    private var weatherRequestInFlight = false

    public init() {
        let central = BluetoothCentral()
        let transport = MultiLinkTransport(central: central)
        self.central = central
        self.transport = transport
        self.gfdiClient = GFDIClient(transport: transport)
    }

    // MARK: - Service Callback Setters

    public func setWeatherProvider(
        _ provider: (@Sendable (WeatherRequest) async throws -> [GFDIMessage])?
    ) {
        weatherProvider = provider
    }

    public func setMusicCommandHandler(_ handler: (@Sendable (UInt8) -> Void)?) {
        musicCommandHandler = handler
    }

    public func setFindMyPhoneHandler(_ handler: (@Sendable (FindMyPhoneEvent) -> Void)?) {
        findMyPhoneHandler = handler
    }

    public func setWatchInitiatedSyncHandler(
        _ handler: (@Sendable ([(url: URL, fileIndex: UInt16)]) async -> Void)?
    ) {
        watchInitiatedSyncHandler = handler
    }

    /// Push one or more MUSIC_CONTROL_ENTITY_UPDATE messages to the watch.
    /// No-ops when not connected.
    public func sendMusicEntityUpdate(_ messages: [GFDIMessage]) async {
        guard _isConnected else { return }
        for msg in messages {
            try? await gfdiClient.send(message: msg)
        }
    }

    // MARK: - Connection State Stream

    public nonisolated func connectionStateStream() -> AsyncStream<ConnectionState> {
        AsyncStream { continuation in
            Task { await self.storeConnectionStateContinuation(continuation) }
            continuation.onTermination = { @Sendable _ in
                Task { await self.clearConnectionStateContinuation() }
            }
        }
    }

    private func storeConnectionStateContinuation(_ cont: AsyncStream<ConnectionState>.Continuation) {
        connectionStateContinuation = cont
    }

    private func clearConnectionStateContinuation() {
        connectionStateContinuation = nil
    }

    // MARK: - Watch Sync Progress / Activity Streams

    public nonisolated func watchSyncProgressStream() -> AsyncStream<SyncProgress> {
        AsyncStream { continuation in
            Task { await self.storeWatchSyncProgressContinuation(continuation) }
            continuation.onTermination = { @Sendable _ in
                Task { await self.clearWatchSyncProgressContinuation() }
            }
        }
    }

    private func storeWatchSyncProgressContinuation(_ cont: AsyncStream<SyncProgress>.Continuation) {
        watchSyncProgressContinuation = cont
    }

    private func clearWatchSyncProgressContinuation() {
        watchSyncProgressContinuation = nil
    }

    public nonisolated func watchActivityStream() -> AsyncStream<WatchActivityEvent> {
        AsyncStream { continuation in
            Task { await self.storeWatchActivityContinuation(continuation) }
            continuation.onTermination = { @Sendable _ in
                Task { await self.clearWatchActivityContinuation() }
            }
        }
    }

    private func storeWatchActivityContinuation(_ cont: AsyncStream<WatchActivityEvent>.Continuation) {
        watchActivityContinuation = cont
    }

    private func clearWatchActivityContinuation() {
        watchActivityContinuation = nil
    }

    private func emitActivity(_ kind: WatchActivityKind) {
        watchActivityContinuation?.yield(WatchActivityEvent(kind: kind))
    }

    private func handleUnexpectedDisconnect(_ error: Error?) {
        guard _isConnected else { return }
        _isConnected = false
        _connectedDevice = nil
        BLELogger.transport.info("Unexpected BLE disconnect: \(error?.localizedDescription ?? "unknown")")
        connectionStateContinuation?.yield(.disconnected)
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
        hasConnectedOnce = false
        BLELogger.auth.info("Pairing with: \(device.name) (\(device.identifier))")

        try await central.connect(identifier: device.identifier)
        try await central.discoverServices()

        await central.setDisconnectHandler { [self] error in
            Task { await self.handleUnexpectedDisconnect(error) }
        }

        let mtu = await central.negotiatedMTU
        await transport.setMaxWriteSize(mtu)
        BLELogger.auth.debug("Negotiated MTU: \(mtu)")

        do {
            // ML protocol setup: CLOSE_ALL + REGISTER_ML(GFDI) → handle.
            try await transport.initializeGFDI(timeout: .seconds(10))

            // Now start GFDI receive loop and run the device-initiated handshake.
            await gfdiClient.startReceiving()

            // Handle async messages that arrive outside explicit request/response waits.
            await gfdiClient.setUnsolicitedHandler { [weak self] msg in
                guard let self else { return }
                Task { await self.handleUnsolicited(msg) }
            }

            let info = try await runHandshake()

            if info.maxPacketSize > 0 {
                maxPacketSize = Int(info.maxPacketSize)
            }

            _isConnected = true
            let paired = PairedDevice(
                identifier: device.identifier,
                name: info.deviceName.isEmpty ? device.name : info.deviceName,
                model: info.deviceModel.isEmpty ? nil : info.deviceModel,
                productID: info.productNumber
            )
            _connectedDevice = paired
            connectionStateContinuation?.yield(.connected(deviceName: paired.name))
            await central.startRSSIPolling()
            BLELogger.auth.info("Pairing complete: \(paired.name)")
            return paired
        } catch {
            BLELogger.auth.error("Pairing failed: \(error.localizedDescription)")
            await gfdiClient.stopReceiving()
            // Best-effort: ask the watch to release the GFDI handle before
            // we drop the BLE link, so its handle pool doesn't saturate
            // across repeated failed pair attempts.
            await transport.gracefulShutdown()
            await central.disconnect()
            throw error
        }
    }

    /// Handles messages that arrive outside an explicit `waitForMessage`.
    ///
    /// After the initial handshake the watch sends a stream of post-pair requests
    /// (CURRENT_TIME_REQUEST, MUSIC_CONTROL_CAPABILITIES, PROTOBUF_REQUEST,
    /// SYNCHRONIZATION, WEATHER_REQUEST, etc.) and retransmits each every ~1 s
    /// until it gets an answer.  We must at minimum ACK every non-RESPONSE message.
    private func handleUnsolicited(_ msg: GFDIMessage) async {
        let client = gfdiClient
        switch msg.type {
        case .authNegotiation:
            if let auth = try? AuthNegotiationMessage.decode(from: msg.payload) {
                BLELogger.auth.info("AUTH_NEGOTIATION (async): unk=\(auth.unknown) flags=\(auth.authFlags)")
                let ack = AuthNegotiationStatusResponse(echoing: auth, status: .guessOk)
                try? await client.send(message: ack.toMessage())
            }

        case .response:
            if let decoded = try? GFDIResponse.decode(from: msg.payload), decoded.status != 0 {
                BLELogger.gfdi.warning(
                    "Unsolicited RESPONSE NACK: originalType=0x\(String(format: "%04X", decoded.originalType)) status=\(decoded.status)"
                )
            } else {
                BLELogger.gfdi.debug("Unsolicited RESPONSE ACK")
            }

        case .currentTimeRequest:
            await Self.respondToCurrentTimeRequest(msg, via: client)

        case .protobufRequest:
            // Gadgetbridge replies with a RESPONSE (0x1388) carrying extended
            // protobuf-status fields — not a full PROTOBUF_RESPONSE (0x13B4).
            // Wire: [originalType LE][status][requestId LE][dataOffset LE][chunkStatus][statusCode]
            let requestId: UInt16
            if msg.payload.count >= 2 {
                requestId = UInt16(msg.payload[0]) | (UInt16(msg.payload[1]) << 8)
            } else {
                requestId = 0
            }
            BLELogger.gfdi.debug("PROTOBUF_REQUEST #\(requestId) — sending ProtobufStatusMessage ACK")
            var extra = Data()
            extra.appendUInt16LE(requestId)
            extra.appendUInt32LE(0)  // dataOffset = 0
            extra.append(0)          // chunkStatus = KEPT
            extra.append(0)          // statusCode = NO_ERROR
            let pbAck = GFDIResponse(originalType: .protobufRequest, status: .ack, additionalPayload: extra)
            try? await client.send(message: pbAck.toMessage())

        case .musicControlCapabilities:
            let commands = GarminMusicControlCommand.allCases.map(\.rawValue)
            BLELogger.gfdi.info("MUSIC_CONTROL_CAPABILITIES — advertising \(commands.count) commands")
            var extra = Data()
            extra.append(UInt8(commands.count))
            extra.append(contentsOf: commands)
            let capsAck = GFDIResponse(
                originalType: .musicControlCapabilities,
                status: .ack,
                additionalPayload: extra
            )
            try? await client.send(message: capsAck.toMessage())

        case .musicControl:
            let ack = GFDIResponse(originalType: .musicControl, status: .ack)
            try? await client.send(message: ack.toMessage())
            if msg.payload.count >= 1 {
                let ordinal = msg.payload[0]
                BLELogger.gfdi.info("MUSIC_CONTROL command=\(ordinal)")
                musicCommandHandler?(ordinal)
            }

        case .weatherRequest:
            await handleWeatherRequest(msg)

        case .findMyPhoneRequest:
            BLELogger.gfdi.info("FIND_MY_PHONE_REQUEST")
            let ack = GFDIResponse(originalType: .findMyPhoneRequest, status: .ack)
            try? await client.send(message: ack.toMessage())
            findMyPhoneHandler?(.started)
            emitActivity(.findMyPhone)

        case .findMyPhoneCancel:
            BLELogger.gfdi.info("FIND_MY_PHONE_CANCEL")
            let ack = GFDIResponse(originalType: .findMyPhoneCancel, status: .ack)
            try? await client.send(message: ack.toMessage())
            findMyPhoneHandler?(.cancelled)
            emitActivity(.findMyPhone)

        case .synchronization:
            await handleSynchronizationMessage(msg)

        case .notificationSubscription:
            // The watch's response format is RESPONSE(0x1388) carrying:
            //   [originalType=13AC LE][status][notificationStatus][enableRaw][unk]
            // A bare ACK or NAK with no extra bytes leaves the watch retransmitting
            // every ~1 s. Match Gadgetbridge: status=ACK, notificationStatus=DISABLED,
            // echo enable byte, unk=0. iOS notifications still reach the watch via ANCS.
            // Reference: Gadgetbridge NotificationSubscriptionStatusMessage.java +
            // GarminSupport.java (NotificationSubscriptionDeviceEvent handler).
            let enableRaw: UInt8 = msg.payload.first ?? 0
            var extra = Data()
            extra.append(0x00)       // notificationStatus = ENABLED (matches Gadgetbridge default)
            extra.append(enableRaw)  // echo enable
            extra.append(0x00)       // unk
            BLELogger.gfdi.debug("NOTIFICATION_SUBSCRIPTION — ACK+ENABLED")
            let resp = GFDIResponse(
                originalType: .notificationSubscription,
                status: .ack,
                additionalPayload: extra
            )
            try? await client.send(message: resp.toMessage())

        default:
            BLELogger.gfdi.debug("ACKing unsolicited 0x\(String(format: "%04X", msg.type.rawValue))")
            let ack = GFDIResponse(originalType: msg.type, status: .ack)
            try? await client.send(message: ack.toMessage())
        }
    }

    /// Handle a watch-initiated SYNCHRONIZATION (5037) message.
    ///
    /// If the bitmask says the watch has relevant data AND no sync is already
    /// running, start a new watch-initiated sync for all supported directories.
    private func handleSynchronizationMessage(_ msg: GFDIMessage) async {
        guard let sync = try? SynchronizationMessage.decode(from: msg.payload) else {
            BLELogger.sync.warning("SYNCHRONIZATION: failed to decode payload")
            return
        }
        BLELogger.sync.info("SYNCHRONIZATION type=\(sync.syncType) bitmask=0x\(String(format: "%016X", sync.bitmask)) shouldProceed=\(sync.shouldProceed)")

        guard sync.shouldProceed else { return }
        guard activeSyncTask == nil else {
            BLELogger.sync.info("SYNCHRONIZATION: sync already in progress, ignoring")
            return
        }

        let client = gfdiClient
        let pktSize = maxPacketSize
        // The public progress stream is long-lived — yielding `.completed` /
        // `.failed` doesn't finish it, so we can pass the continuation straight
        // through. Each new watch-initiated sync emits its own start→completed
        // sequence onto the same stream.
        let progressContinuation = watchSyncProgressContinuation
        let task = Task<[(url: URL, fileIndex: UInt16)], Error> {
            let session = FileSyncSession(client: client, maxPacketSize: pktSize)
            do {
                let pairs = try await session.run(
                    directories: Set(FITDirectory.allCases),
                    progress: progressContinuation,
                    watchInitiated: true
                )
                return pairs.map { (url: $0.url, fileIndex: $0.entry.fileIndex) }
            } catch {
                progressContinuation?.yield(.failed(error))
                throw error
            }
        }
        activeSyncTask = task
        Task { [weak self] in
            let pairs = (try? await task.value) ?? []
            await self?.clearActiveSyncTask()
            if !pairs.isEmpty {
                await self?.watchInitiatedSyncHandler?(pairs)
            }
        }
    }

    private func clearActiveSyncTask() {
        activeSyncTask = nil
    }

    /// Handle a WEATHER_REQUEST from the watch.
    ///
    /// Parses the lat/lon/format payload, calls the injected `weatherProvider`
    /// closure (which runs WeatherKit on the app layer), and sends the resulting
    /// FIT_DEFINITION + FIT_DATA messages back inline.  Guards against concurrent
    /// fetches: the watch retransmits every ~5 s and WeatherKit takes 1–3 s.
    private func handleWeatherRequest(_ msg: GFDIMessage) async {
        guard !weatherRequestInFlight else {
            BLELogger.gfdi.debug("WEATHER_REQUEST: fetch already in flight, skipping duplicate")
            return
        }
        guard let provider = weatherProvider else {
            BLELogger.gfdi.debug("WEATHER_REQUEST: no provider set, ignoring")
            return
        }
        guard let request = try? WeatherRequestParser.decode(from: msg.payload) else {
            BLELogger.gfdi.warning("WEATHER_REQUEST: failed to parse payload (\(msg.payload.count) bytes)")
            return
        }
        BLELogger.gfdi.info(
            "WEATHER_REQUEST lat=\(String(format: "%.4f", request.latitude)) "
          + "lon=\(String(format: "%.4f", request.longitude)) hours=\(request.hoursOfForecast)"
        )

        // ACK the WEATHER_REQUEST before sending FIT messages.  Without this
        // the watch treats the FIT_DEFINITION / FIT_DATA pair as unrelated
        // unsolicited messages and keeps retransmitting every 5 s.
        let weatherAck = GFDIResponse(originalType: .weatherRequest, status: .ack)
        try? await gfdiClient.send(message: weatherAck.toMessage())

        weatherRequestInFlight = true
        defer { weatherRequestInFlight = false }
        emitActivity(.weather)

        do {
            let fitMessages = try await provider(request)
            for fitMsg in fitMessages {
                let hex = fitMsg.payload.map { String(format: "%02X", $0) }.joined(separator: " ")
                BLELogger.gfdi.debug("WEATHER FIT type=0x\(String(format: "%04X", fitMsg.type.rawValue)) payload[\(fitMsg.payload.count)]: \(hex)")
                try await gfdiClient.send(message: fitMsg)
            }
            BLELogger.gfdi.info("WEATHER_REQUEST: pushed \(fitMessages.count) FIT messages")
        } catch {
            BLELogger.gfdi.error("WEATHER_REQUEST: provider error — \(error)")
            // Silence: the watch will retry in ~5 s.
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

    /// Phase 1 of the GFDI handshake — always runs on both first pair and reconnect.
    ///
    /// Handles DEVICE_INFORMATION, CONFIGURATION exchange, SUPPORTED_FILE_TYPES_REQUEST,
    /// and DEVICE_SETTINGS. Does NOT send pairing lifecycle events.
    private func runHandshakePreamble() async throws -> DeviceInformationMessage {
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

        // SUPPORTED_FILE_TYPES_REQUEST is required; the watch's state machine
        // waits for this after CONFIGURATION before accepting SYSTEM_EVENTs.
        BLELogger.auth.debug("Sending SUPPORTED_FILE_TYPES_REQUEST")
        try await gfdiClient.send(message: SupportedFileTypesRequestMessage().toMessage())

        BLELogger.auth.debug("Sending DEVICE_SETTINGS")
        try await gfdiClient.send(message: SetDeviceSettingsMessage.defaults().toMessage())

        return devInfo
    }

    /// The device-initiated GFDI handshake (after ML init has assigned a handle).
    ///
    /// Calls `runHandshakePreamble()` then sends pairing lifecycle events only on
    /// the first successful connect. On reconnects, sends only SYNC_READY so the
    /// watch home screen appears immediately without re-running the setup wizard.
    private func runHandshake() async throws -> DeviceInformationMessage {
        let devInfo = try await runHandshakePreamble()

        if !hasConnectedOnce {
            BLELogger.auth.debug("Sending SYNC_READY / PAIR_COMPLETE / SYNC_COMPLETE / SETUP_WIZARD_COMPLETE")
            try await gfdiClient.send(message: SystemEventMessage(eventType: .syncReady).toMessage())
            try await gfdiClient.send(message: SystemEventMessage(eventType: .pairComplete).toMessage())
            try await gfdiClient.send(message: SystemEventMessage(eventType: .syncComplete).toMessage())
            try await gfdiClient.send(message: SystemEventMessage(eventType: .setupWizardComplete).toMessage())
            hasConnectedOnce = true
        } else {
            BLELogger.auth.debug("Reconnect: sending SYNC_READY only (skipping pairing events)")
            try await gfdiClient.send(message: SystemEventMessage(eventType: .syncReady).toMessage())
        }

        return devInfo
    }

    // MARK: - Connection

    public func connect(_ device: PairedDevice) async throws {
        BLELogger.transport.info("Connecting to paired device: \(device.name)")

        try await central.connect(identifier: device.identifier)
        try await central.discoverServices()

        await central.setDisconnectHandler { [self] error in
            Task { await self.handleUnexpectedDisconnect(error) }
        }

        let mtu = await central.negotiatedMTU
        await transport.setMaxWriteSize(mtu)

        try await transport.initializeGFDI(timeout: .seconds(10))
        await gfdiClient.startReceiving()

        await gfdiClient.setUnsolicitedHandler { [weak self] msg in
            guard let self else { return }
            Task { await self.handleUnsolicited(msg) }
        }

        let info = try await runHandshake()
        if info.maxPacketSize > 0 {
            maxPacketSize = Int(info.maxPacketSize)
        }
        _isConnected = true
        _connectedDevice = device
        connectionStateContinuation?.yield(.connected(deviceName: device.name))
        await central.startRSSIPolling()
        BLELogger.transport.info("Reconnected to: \(device.name)")
    }

    public func disconnect() async {
        BLELogger.transport.info("Disconnecting")
        // Mark as disconnected and clear the handler before tearing down BLE
        // so the CoreBluetooth didDisconnect callback doesn't double-fire.
        _isConnected = false
        _connectedDevice = nil
        connectionStateContinuation?.yield(.disconnected)
        await central.stopRSSIPolling()
        await central.setDisconnectHandler(nil)
        await gfdiClient.stopReceiving()
        // Release the watch's GFDI handle before tearing down BLE so its
        // ML handle pool stays clean across reconnects.
        await transport.gracefulShutdown()
        await central.disconnect()
    }

    // MARK: - File Sync

    public func pullFITFiles(
        directories: Set<FITDirectory>,
        progress: AsyncStream<SyncProgress>.Continuation?
    ) async throws -> [(url: URL, fileIndex: UInt16)] {
        guard _isConnected else {
            progress?.yield(.failed(SyncError.notConnected))
            throw SyncError.notConnected
        }

        // Cancel any in-flight watch-initiated sync before starting a phone-initiated one.
        activeSyncTask?.cancel()
        activeSyncTask = nil

        let client = gfdiClient
        let pktSize = maxPacketSize
        let task = Task<[(url: URL, fileIndex: UInt16)], Error> {
            let session = FileSyncSession(client: client, maxPacketSize: pktSize)
            let pairs = try await session.run(directories: directories, progress: progress, watchInitiated: false)
            return pairs.map { (url: $0.url, fileIndex: $0.entry.fileIndex) }
        }
        activeSyncTask = task
        defer { activeSyncTask = nil }
        return try await task.value
    }

    /// Send the archive flag for one file after it has been successfully parsed and
    /// persisted by the app layer. Logs and returns without sending if disconnected.
    public func archiveFITFile(fileIndex: UInt16) async {
        guard _isConnected else {
            BLELogger.sync.warning("Sync: cannot archive fileIndex=\(fileIndex) — not connected")
            return
        }
        let flagMsg = SetFileFlagsMessage(fileIndex: fileIndex).toMessage()
        do {
            let response = try await gfdiClient.sendAndWait(flagMsg, awaitType: .response, timeout: .seconds(5))
            let decoded = try GFDIResponse.decode(from: response.payload)
            if decoded.originalType != GFDIMessageType.setFileFlag.rawValue {
                BLELogger.sync.warning("Sync: archive fileIndex=\(fileIndex) got mismatched response originalType=0x\(String(format: "%04X", decoded.originalType))")
                return
            }
            if decoded.status == GFDIResponse.Status.ack.rawValue {
                BLELogger.sync.info("Sync: archived fileIndex=\(fileIndex)")
                emitActivity(.archive)
            } else {
                BLELogger.sync.warning("Sync: archive fileIndex=\(fileIndex) NACK status=\(decoded.status)")
            }
        } catch {
            BLELogger.sync.warning("Sync: archive fileIndex=\(fileIndex) failed: \(error.localizedDescription)")
        }
    }

    public func cancelSync() async {
        activeSyncTask?.cancel()
        activeSyncTask = nil
    }

    public func notifyBackground() async {
        guard _isConnected else { return }
        try? await gfdiClient.send(message: SystemEventMessage(eventType: .hostDidEnterBackground).toMessage())
    }

    public func notifyForeground() async {
        guard _isConnected else { return }
        try? await gfdiClient.send(message: SystemEventMessage(eventType: .hostDidEnterForeground).toMessage())
    }

    public func uploadCourse(
        _ url: URL,
        progress: AsyncStream<SyncProgress>.Continuation?
    ) async throws -> UInt16 {
        let data = try Data(contentsOf: url)
        let session = FileUploadSession(client: gfdiClient, maxPacketSize: maxPacketSize)
        return try await session.upload(data: data, progress: progress)
    }

    // MARK: - Properties

    public var isConnected: Bool { _isConnected }
    public var connectedDevice: PairedDevice? { _connectedDevice }

    // MARK: - Raw Send

    public func sendRaw(message: GFDIMessage) async throws {
        try await gfdiClient.send(message: message)
    }
}
