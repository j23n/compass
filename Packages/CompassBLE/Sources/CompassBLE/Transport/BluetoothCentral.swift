import Foundation
@preconcurrency import CoreBluetooth
import os

/// Actor wrapping `CBCentralManager` for Garmin BLE communication.
///
/// Manages all CoreBluetooth interactions: scanning, connecting, service
/// discovery, characteristic read/write, and notification subscriptions.
///
/// Garmin Multi-Link V2 UUIDs (from Gadgetbridge CommunicatorV2 / 02-ble.md):
/// - Service: `6A4E2800-667B-11E3-949A-0800200C9A66`
/// - Write (phone → watch): `6A4E2820-667B-11E3-949A-0800200C9A66`
/// - Notify (watch → phone): `6A4E2810-667B-11E3-949A-0800200C9A66`
///
/// Scanning does NOT filter by service UUID because many Garmin devices
/// (including the Instinct Solar) don't advertise it. Instead, we scan
/// for all BLE devices and filter by known Garmin device name patterns,
/// matching Gadgetbridge's approach.
///
/// Delegate callbacks are bridged to Swift concurrency using `AsyncStream` and
/// `CheckedContinuation`.
///
/// Reference: Gadgetbridge `GarminSupport.java`, `CommunicatorV2.java`
public actor BluetoothCentral {

    // MARK: - Garmin Service UUID Strings

    /// The Garmin Multi-Link V2 BLE service UUID.
    public static let serviceUUIDString = "6A4E2800-667B-11E3-949A-0800200C9A66"

    /// V2 Multi-Link write characteristic UUID (phone → watch, channel 0).
    /// Gadgetbridge: CommunicatorV2.UUID_CHARACTERISTIC_GARMIN_ML_GFDI_SEND
    public static let writeCharacteristicUUIDString = "6A4E2820-667B-11E3-949A-0800200C9A66"

    /// V2 Multi-Link notify characteristic UUID (watch → phone, channel 0).
    /// Gadgetbridge: CommunicatorV2.UUID_CHARACTERISTIC_GARMIN_ML_GFDI_RECEIVE
    public static let notifyCharacteristicUUIDString = "6A4E2810-667B-11E3-949A-0800200C9A66"

    /// All known Garmin service UUIDs (V0, V1, V2) for post-connection service discovery.
    private static let allGarminServiceUUIDs: [CBUUID] = [
        CBUUID(string: "6A4E2800-667B-11E3-949A-0800200C9A66"), // V2 Multi-Link
        CBUUID(string: "6A4E2401-667B-11E3-949A-0800200C9A66"), // V1
        CBUUID(string: "9B012401-BC30-CE9A-E111-0F67E491ABDE"), // V0
    ]

    /// Known Garmin device name prefixes used to filter scan results.
    /// Sourced from Gadgetbridge device coordinators.
    private static let garminNamePrefixes: [String] = [
        "Instinct", "Forerunner", "Fenix", "fenix", "Enduro",
        "Venu", "vivoactive", "vivomove", "vivosmart", "vivofit",
        "Lily", "Approach", "Descent", "MARQ", "tactix", "Tactix",
        "Swim", "Edge", "D2", "epix", "Epix", "quatix", "Quatix",
        "Garmin",
    ]

    // MARK: - CBUUID Constants

    private static let serviceUUID = CBUUID(string: serviceUUIDString)
    private static let writeUUID = CBUUID(string: writeCharacteristicUUIDString)
    private static let notifyUUID = CBUUID(string: notifyCharacteristicUUIDString)

    // MARK: - State

    /// The underlying CBCentralManager. Created on first scan to avoid
    /// triggering the Bluetooth permission prompt prematurely.
    private var centralManager: CBCentralManager?

    /// The delegate adapter that bridges CB callbacks to this actor.
    private var delegateAdapter: CentralManagerDelegateAdapter?

    /// The currently connected peripheral.
    private var connectedPeripheral: CBPeripheral?

    /// The discovered write characteristic.
    private var writeCharacteristic: CBCharacteristic?

    /// The discovered notify characteristic.
    private var notifyCharacteristic: CBCharacteristic?

    /// Scan continuation — yields discovered devices.
    private var scanContinuation: AsyncStream<DiscoveredDevice>.Continuation?

    /// Notification data continuation — yields raw BLE notification bytes.
    /// Held on the delegate adapter so `didUpdateValueFor` can yield
    /// synchronously and preserve CoreBluetooth's wire order. See the
    /// adapter for the full rationale.
    private var notificationContinuation: AsyncStream<Data>.Continuation? {
        get { delegateAdapter?.notificationContinuation }
        set { delegateAdapter?.notificationContinuation = newValue }
    }

    /// Connection continuation — resumed when BLE connect succeeds or fails.
    private var connectionContinuation: CheckedContinuation<Void, Error>?

    /// Service discovery continuation — resumed when characteristics are found.
    private var discoveryServiceContinuation: CheckedContinuation<Void, Error>?

    /// Characteristic discovery continuation.
    private var discoveryCharacteristicContinuation: CheckedContinuation<Void, Error>?

    /// One pending write — the data we'll hand to `peripheral.writeValue`
    /// plus the continuation we resume once iOS accepts the bytes.
    private struct PendingWrite {
        let data: Data
        let continuation: CheckedContinuation<Void, Error>
    }

    /// FIFO of writes waiting their turn. Writes from multiple tasks are
    /// serialized through this queue so concurrent callers can't trample
    /// each other's continuations (which would leak via the runtime's
    /// "SWIFT TASK CONTINUATION MISUSE" warning and block whichever task
    /// loses the race forever).
    private var writeQueue: [PendingWrite] = []

    /// Powered-on continuation — resumed when CBCentralManager reports .poweredOn.
    private var poweredOnContinuation: CheckedContinuation<Void, Error>?

    /// Called after an unexpected BLE disconnect so upper layers can update state.
    private var disconnectHandler: (@Sendable (Error?) -> Void)?

    /// Periodic RSSI poll — detects silent link loss before the 6 s supervision timeout.
    private var rssiTask: Task<Void, Never>?

    // MARK: - Init

    public init() {}

    /// Register a handler that fires when the BLE link drops unexpectedly.
    /// Pass `nil` to unregister (e.g., before a clean `disconnect()` call).
    public func setDisconnectHandler(_ handler: (@Sendable (Error?) -> Void)?) {
        disconnectHandler = handler
    }

    // MARK: - RSSI Heartbeat

    /// Poll RSSI every 15 s to detect silent link loss.
    /// CoreBluetooth fires `didDisconnectPeripheral` when `readRSSI` fails,
    /// which propagates up through `didDisconnect` and triggers reconnect.
    public func startRSSIPolling() {
        rssiTask?.cancel()
        rssiTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let p = connectedPeripheral else { break }
                p.readRSSI()
            }
        }
    }

    public func stopRSSIPolling() {
        rssiTask?.cancel()
        rssiTask = nil
    }

    // MARK: - Internal: Ensure Central Manager

    /// Lazily create the CBCentralManager and wait for it to power on.
    private func ensureCentralManager() async throws {
        if centralManager != nil { return }

        BLELogger.transport.info("Creating CBCentralManager")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.poweredOnContinuation = continuation
            let adapter = CentralManagerDelegateAdapter(central: self)
            self.delegateAdapter = adapter
            let options: [String: Any] = [
                CBCentralManagerOptionRestoreIdentifierKey: "com.compass.app.central"
            ]
            self.centralManager = CBCentralManager(delegate: adapter, queue: nil, options: options)
        }

        BLELogger.transport.info("CBCentralManager powered on")
    }

    // MARK: - Scanning

    /// Scan for Garmin devices.
    ///
    /// Scans for ALL BLE devices (no service UUID filter) because many Garmin
    /// devices don't include their service UUID in the advertisement packet.
    /// Discovered devices are filtered by name prefix to match known Garmin models.
    /// This matches Gadgetbridge's approach (DiscoveryActivityV2.java).
    public func scanForDevices() -> AsyncStream<DiscoveredDevice> {
        BLELogger.transport.info("Starting BLE scan for Garmin devices (no service filter)")

        return AsyncStream { continuation in
            self.scanContinuation = continuation

            Task {
                do {
                    try await self.ensureCentralManager()
                    BLELogger.transport.debug("Scanning for all BLE devices, filtering by Garmin name prefixes")
                    self.centralManager?.scanForPeripherals(
                        withServices: nil,
                        options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
                    )
                } catch {
                    BLELogger.transport.error("Failed to start scan: \(error.localizedDescription)")
                    continuation.finish()
                }
            }

            continuation.onTermination = { @Sendable _ in
                Task { await self.stopScanning() }
            }
        }
    }

    /// Stop the active BLE scan.
    public func stopScanning() {
        BLELogger.transport.info("Stopping BLE scan")
        centralManager?.stopScan()
        scanContinuation?.finish()
        scanContinuation = nil
    }

    // MARK: - Connection

    /// Connect to a peripheral by its identifier.
    public func connect(identifier: UUID) async throws {
        BLELogger.transport.info("Connecting to peripheral: \(identifier)")

        try await ensureCentralManager()

        guard let peripherals = centralManager?.retrievePeripherals(withIdentifiers: [identifier]).first else {
            BLELogger.transport.error("Peripheral not found: \(identifier)")
            throw PairingError.deviceNotFound
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.connectionContinuation = continuation
            
            // TODO: Re-evaluate CBConnectPeripheralOptionEnableAutoReconnect once we have a full Apple Developer account.
            // Using it previously resulted in "BLE connection failed: One or more parameters were invalid."
            self.centralManager?.connect(peripherals, options: nil)
        }

        self.connectedPeripheral = peripherals
        // Set the delegate adapter as the peripheral delegate so we get callbacks
        self.connectedPeripheral?.delegate = self.delegateAdapter
        BLELogger.transport.info("Connected to peripheral: \(identifier)")
    }

    /// Disconnect from the currently connected peripheral.
    public func disconnect() {
        BLELogger.transport.info("Disconnecting from peripheral")

        if let peripheral = connectedPeripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }

        connectedPeripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        notificationContinuation?.finish()
        notificationContinuation = nil

        // Resume any pending continuations with a cancellation error so we
        // don't leak them across sessions (which triggers the runtime's
        // "SWIFT TASK CONTINUATION MISUSE" warning on the next attempt).
        let queued = writeQueue
        writeQueue.removeAll()
        for w in queued { w.continuation.resume(throwing: PairingError.deviceNotFound) }
        connectionContinuation?.resume(throwing: PairingError.deviceNotFound)
        connectionContinuation = nil
        discoveryServiceContinuation?.resume(throwing: PairingError.deviceNotFound)
        discoveryServiceContinuation = nil
        discoveryCharacteristicContinuation?.resume(throwing: PairingError.deviceNotFound)
        discoveryCharacteristicContinuation = nil
    }

    // MARK: - Service Discovery

    /// Discover the Garmin service and its characteristics on the connected peripheral.
    ///
    /// Discovers all known Garmin service UUIDs (V0, V1, V2) and then discovers
    /// ALL characteristics on the found service. Logs everything for debugging.
    /// Looks for the V2 Multi-Link characteristics first (2810/2820), then
    /// falls back to legacy (2801/2802) if V2 aren't found.
    public func discoverServices() async throws {
        BLELogger.transport.info("Discovering Garmin services")

        guard let peripheral = connectedPeripheral else {
            throw PairingError.deviceNotFound
        }

        // Discover all known Garmin services
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.discoveryServiceContinuation = continuation
            peripheral.discoverServices(Self.allGarminServiceUUIDs)
        }

        // Log all discovered services
        if let services = peripheral.services {
            for svc in services {
                BLELogger.transport.info("Found service: \(svc.uuid)")
            }
        }

        // Prefer V2 service, fall back to V1/V0
        guard let service = peripheral.services?.first(where: { Self.allGarminServiceUUIDs.contains($0.uuid) }) else {
            BLELogger.transport.error("No Garmin service found on peripheral")
            if let services = peripheral.services {
                for svc in services {
                    BLELogger.transport.error("  Available service: \(svc.uuid)")
                }
            }
            throw PairingError.deviceNotFound
        }
        BLELogger.transport.info("Using Garmin service: \(service.uuid)")

        // Discover ALL characteristics (not just the ones we expect) for debugging
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.discoveryCharacteristicContinuation = continuation
            peripheral.discoverCharacteristics(nil, for: service)
        }

        // Log all discovered characteristics
        if let chars = service.characteristics {
            for c in chars {
                let props = c.properties
                var propStrs: [String] = []
                if props.contains(.read) { propStrs.append("read") }
                if props.contains(.write) { propStrs.append("write") }
                if props.contains(.writeWithoutResponse) { propStrs.append("writeNoResp") }
                if props.contains(.notify) { propStrs.append("notify") }
                if props.contains(.indicate) { propStrs.append("indicate") }
                BLELogger.transport.info("  Characteristic: \(c.uuid) [\(propStrs.joined(separator: ", "))]")
            }
        }

        // Look for V2 Multi-Link characteristics first (2810 notify, 2820 write)
        writeCharacteristic = service.characteristics?.first(where: { $0.uuid == Self.writeUUID })
        notifyCharacteristic = service.characteristics?.first(where: { $0.uuid == Self.notifyUUID })

        // Fallback: try legacy UUIDs (2801 write, 2802 notify) if V2 not found
        if writeCharacteristic == nil || notifyCharacteristic == nil {
            let legacyWriteUUID = CBUUID(string: "6A4E2801-667B-11E3-949A-0800200C9A66")
            let legacyNotifyUUID = CBUUID(string: "6A4E2802-667B-11E3-949A-0800200C9A66")
            if writeCharacteristic == nil {
                writeCharacteristic = service.characteristics?.first(where: { $0.uuid == legacyWriteUUID })
            }
            if notifyCharacteristic == nil {
                notifyCharacteristic = service.characteristics?.first(where: { $0.uuid == legacyNotifyUUID })
            }
            if writeCharacteristic != nil || notifyCharacteristic != nil {
                BLELogger.transport.info("Using legacy V1 characteristic UUIDs")
            }
        }

        if let write = writeCharacteristic {
            BLELogger.transport.info("Write characteristic: \(write.uuid)")
        } else {
            BLELogger.transport.error("Write characteristic NOT FOUND — communication will fail")
        }

        if let notify = notifyCharacteristic {
            BLELogger.transport.info("Notify characteristic: \(notify.uuid)")
            peripheral.setNotifyValue(true, for: notify)
            BLELogger.transport.debug("Subscribed to notifications")
        } else {
            BLELogger.transport.error("Notify characteristic NOT FOUND — communication will fail")
        }

        guard writeCharacteristic != nil, notifyCharacteristic != nil else {
            throw PairingError.authenticationFailed("Required BLE characteristics not found on device")
        }
    }

    // MARK: - Read / Write

    /// Write data to the write characteristic (phone → watch).
    ///
    /// Uses `.withoutResponse`: the Garmin send characteristic only declares
    /// `Write Without Response` in its GATT properties, and the watch firmware
    /// never emits an ATT Write Response PDU — using `.withResponse` makes
    /// every fragment block ~1 s waiting for a response that arrives slowly
    /// or not at all. Gadgetbridge takes the same approach on Android.
    /// Backpressure: drain only while `canSendWriteWithoutResponse` is true,
    /// then wait for `peripheralIsReady(toSendWriteWithoutResponse:)`.
    /// See `docs/gadgetbridge-instinct-pairing.md` §2.
    public func write(data: Data) async throws {
        guard connectedPeripheral != nil, writeCharacteristic != nil else {
            throw PairingError.deviceNotFound
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.writeQueue.append(PendingWrite(data: data, continuation: continuation))
            self.pumpWriteQueue()
        }
    }

    /// Drain the queue while CoreBluetooth can accept writes-without-response.
    /// Once `canSendWriteWithoutResponse` is false, stops and waits for
    /// `peripheralIsReady(toSendWriteWithoutResponse:)` to wake us up.
    private func pumpWriteQueue() {
        while let next = writeQueue.first {
            guard let peripheral = connectedPeripheral, let characteristic = writeCharacteristic else {
                // Connection went away — fail every pending write so callers don't hang.
                let queued = writeQueue
                writeQueue.removeAll()
                for w in queued { w.continuation.resume(throwing: PairingError.deviceNotFound) }
                return
            }
            guard peripheral.canSendWriteWithoutResponse else {
                // Backpressure — wait for peripheralIsReady to drain again.
                return
            }

            writeQueue.removeFirst()
            BLELogger.transport.debug("Writing \(next.data.count) bytes to \(characteristic.uuid)")
            if next.data.count <= 32 {
                BLELogger.transport.debug("Write data hex: \(next.data.map { String(format: "%02X", $0) }.joined())")
            } else {
                let prefix = next.data.prefix(32).map { String(format: "%02X", $0) }.joined()
                BLELogger.transport.debug("Write data hex (first 32): \(prefix)...")
            }
            peripheral.writeValue(next.data, for: characteristic, type: .withoutResponse)
            // .withoutResponse: no callback fires; bytes are accepted into the
            // OS BLE stack synchronously. Resume the caller now.
            next.continuation.resume()
        }
    }

    /// Called from the CB delegate when `peripheralIsReady(toSendWriteWithoutResponse:)`
    /// fires — backpressure has cleared, so resume draining the write queue.
    func didBecomeReadyToWrite() {
        pumpWriteQueue()
    }

    /// Get the stream of notification data from the watch.
    public func notifications() -> AsyncStream<Data> {
        return AsyncStream { continuation in
            self.notificationContinuation = continuation

            continuation.onTermination = { @Sendable _ in
                // Cleanup handled by disconnect()
            }
        }
    }

    /// The MTU (maximum transfer unit) for the connected peripheral.
    public var negotiatedMTU: Int {
        guard let peripheral = connectedPeripheral else { return 20 }
        // maximumWriteValueLength gives us the max payload we can write
        return peripheral.maximumWriteValueLength(for: .withResponse)
    }

    // MARK: - Delegate Callbacks (called by adapter)

    func didRestoreState(peripheralIDs: [UUID]) {
        BLELogger.transport.info("State restoration triggered with \(peripheralIDs.count) peripheral(s)")

        guard let id = peripheralIDs.first,
              let peripheral = centralManager?.retrievePeripherals(withIdentifiers: [id]).first else {
            BLELogger.transport.warning("State restoration: peripheral not retrievable — falling back to reconnect")
            disconnectHandler?(nil)
            return
        }

        connectedPeripheral = peripheral
        peripheral.delegate = delegateAdapter
        BLELogger.transport.info("Restored peripheral: \(peripheral.identifier)")

        // Re-acquire characteristics from the peripheral's already-restored services.
        for service in peripheral.services ?? [] {
            for c in service.characteristics ?? [] {
                if c.uuid == Self.writeUUID { writeCharacteristic = c }
                if c.uuid == Self.notifyUUID { notifyCharacteristic = c }
            }
        }
        BLELogger.transport.info(
            "Restored characteristics — write: \(writeCharacteristic != nil), notify: \(notifyCharacteristic != nil)"
        )

        // Only trigger a full reconnect if the restoration is incomplete (one
        // of the characteristics didn't come back). On a successful restore we
        // keep the existing peripheral and let the BLE pump pick up whatever
        // notification iOS woke us for — tearing the GFDI session down and
        // re-running the auth/MLR handshake doesn't finish within the brief
        // background wake window, which is what caused phone-finder and
        // watch-initiated sync to silently fail in background.
        //
        // Note: this fix alone isn't sufficient for full background BLE — we
        // also need to ensure the CBCentralManager is created early enough at
        // app launch for iOS to deliver `willRestoreState` (currently it's
        // created lazily on first connect, after the UI is up). See
        // docs/issues/background_ble_restoration.md.
        guard writeCharacteristic != nil, notifyCharacteristic != nil else {
            BLELogger.transport.warning("State restoration: missing characteristic, falling back to reconnect")
            disconnectHandler?(nil)
            return
        }
        BLELogger.transport.info("State restoration: full restore, keeping session live")
    }

    func didUpdateState(_ state: CBManagerState) {
        BLELogger.transport.info("Central manager state: \(state.rawValue)")
        switch state {
        case .poweredOn:
            poweredOnContinuation?.resume()
            poweredOnContinuation = nil
        case .poweredOff, .unauthorized, .unsupported:
            poweredOnContinuation?.resume(throwing: PairingError.bluetoothUnavailable)
            poweredOnContinuation = nil
        default:
            break
        }
    }

    func didDiscover(device: DiscoveredDevice) {
        // Filter by known Garmin name prefixes (matching Gadgetbridge's approach)
        let isGarmin = Self.garminNamePrefixes.contains { device.name.hasPrefix($0) }
        if isGarmin {
            BLELogger.transport.info("Discovered Garmin device: \(device.name) (RSSI: \(device.rssi))")
            scanContinuation?.yield(device)
        }
        // Silently ignore non-Garmin devices to avoid log spam
    }

    func didConnect() {
        BLELogger.transport.info("BLE connection established")
        connectionContinuation?.resume()
        connectionContinuation = nil
    }

    func didFailToConnect(error: Error?) {
        let msg = error?.localizedDescription ?? "unknown"
        BLELogger.transport.error("BLE connection failed: \(msg)")
        connectionContinuation?.resume(throwing: error ?? PairingError.connectionTimeout)
        connectionContinuation = nil
    }

    func didDisconnect(error: Error?) {
        BLELogger.transport.info("BLE disconnected: \(error?.localizedDescription ?? "clean")")
        connectedPeripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        notificationContinuation?.finish()
        notificationContinuation = nil

        // Fail any in-flight continuations so callers don't hang indefinitely.
        let queued = writeQueue
        writeQueue.removeAll()
        for w in queued { w.continuation.resume(throwing: error ?? PairingError.deviceNotFound) }
        connectionContinuation?.resume(throwing: error ?? PairingError.deviceNotFound)
        connectionContinuation = nil
        discoveryServiceContinuation?.resume(throwing: error ?? PairingError.deviceNotFound)
        discoveryServiceContinuation = nil
        discoveryCharacteristicContinuation?.resume(throwing: error ?? PairingError.deviceNotFound)
        discoveryCharacteristicContinuation = nil
        disconnectHandler?(error)
    }

    func didDiscoverServices(error: Error?) {
        if let error {
            BLELogger.transport.error("Service discovery failed: \(error.localizedDescription)")
            discoveryServiceContinuation?.resume(throwing: error)
        } else {
            BLELogger.transport.debug("Service discovery complete")
            discoveryServiceContinuation?.resume()
        }
        discoveryServiceContinuation = nil
    }

    func didDiscoverCharacteristics(error: Error?) {
        if let error {
            BLELogger.transport.error("Characteristic discovery failed: \(error.localizedDescription)")
            discoveryCharacteristicContinuation?.resume(throwing: error)
        } else {
            BLELogger.transport.debug("Characteristic discovery complete")
            discoveryCharacteristicContinuation?.resume()
        }
        discoveryCharacteristicContinuation = nil
    }

    func didReadRSSI(error: Error?) {
        if let error {
            BLELogger.transport.info("RSSI read failed — treating as disconnect: \(error.localizedDescription)")
            didDisconnect(error: error)
        }
    }

}

// MARK: - Delegate Adapter

/// Bridges `CBCentralManagerDelegate` and `CBPeripheralDelegate` callbacks to the
/// `BluetoothCentral` actor.
private final class CentralManagerDelegateAdapter: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {

    private weak var central: BluetoothCentral?

    /// Held here, not on the actor, so `didUpdateValueFor` can yield
    /// synchronously from CoreBluetooth's serial delegate queue.
    ///
    /// Why this matters: under bursty arrival (e.g. 25+ fragments of a
    /// multi-fragment GFDI/COBS message in <50 ms during a file download),
    /// wrapping each notification in `Task { await actor.method(...) }`
    /// lets Swift's scheduler reorder the Tasks at the actor mailbox. The
    /// COBS decoder then reads "code" bytes from positions that hold raw
    /// data, producing garbage and downstream CRC mismatches. Yielding
    /// directly from the delegate keeps fragments in wire order;
    /// `AsyncStream.Continuation.yield` is safe to call from any context
    /// and preserves order when called from a single producer.
    private let notificationLock = NSLock()
    private var _notificationContinuation: AsyncStream<Data>.Continuation?

    var notificationContinuation: AsyncStream<Data>.Continuation? {
        get {
            notificationLock.lock()
            defer { notificationLock.unlock() }
            return _notificationContinuation
        }
        set {
            notificationLock.lock()
            _notificationContinuation = newValue
            notificationLock.unlock()
        }
    }

    init(central: BluetoothCentral) {
        self.central = central
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { await self.central?.didUpdateState(central.state) }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let ids = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []).map(\.identifier)
        Task { await self.central?.didRestoreState(peripheralIDs: ids) }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let device = DiscoveredDevice(
            identifier: peripheral.identifier,
            name: peripheral.name ?? "Unknown Garmin",
            rssi: RSSI.intValue
        )
        Task { await self.central?.didDiscover(device: device) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { await self.central?.didConnect() }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        Task { await self.central?.didFailToConnect(error: error) }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        Task { await self.central?.didDisconnect(error: error) }
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        Task { await self.central?.didDiscoverServices(error: error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        Task { await self.central?.didDiscoverCharacteristics(error: error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard let data = characteristic.value else { return }
        if data.count <= 32 {
            BLELogger.transport.debug("Notification (\(data.count)B): \(data.map { String(format: "%02X", $0) }.joined())")
        } else {
            let prefix = data.prefix(32).map { String(format: "%02X", $0) }.joined()
            BLELogger.transport.debug("Notification (\(data.count)B): \(prefix)...")
        }
        notificationLock.lock()
        let cont = _notificationContinuation
        notificationLock.unlock()
        cont?.yield(data)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        Task { await self.central?.didBecomeReadyToWrite() }
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: (any Error)?) {
        Task { await self.central?.didReadRSSI(error: error) }
    }
}
