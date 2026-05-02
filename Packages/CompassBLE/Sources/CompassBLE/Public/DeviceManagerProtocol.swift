import Foundation

/// Protocol that both ``GarminDeviceManager`` and ``MockGarminDevice`` conform to.
///
/// This allows the app layer to swap between real BLE communication and a mock
/// implementation for testing, previews, and simulator builds.
///
/// All methods are async because the real implementation involves BLE I/O. The
/// protocol is `Sendable` so it can be stored in `@Observable` view models.
public protocol DeviceManagerProtocol: Sendable {
    /// Begin scanning for nearby Garmin devices.
    /// Returns an `AsyncStream` that yields devices as they are discovered.
    func discover() -> AsyncStream<DiscoveredDevice>

    /// Stop scanning for devices.
    func stopDiscovery() async

    /// Pair with a discovered device. Performs the GFDI handshake and authentication.
    /// - Parameter device: The device to pair with.
    /// - Returns: A paired device with model information from the device info exchange.
    func pair(_ device: DiscoveredDevice) async throws -> PairedDevice

    /// Connect to a previously paired device.
    /// - Parameter device: The paired device to reconnect to.
    func connect(_ device: PairedDevice) async throws

    /// Disconnect from the currently connected device.
    func disconnect() async

    /// Pull FIT files from the specified directories on the connected device.
    /// - Parameters:
    ///   - directories: The set of FIT directories to sync.
    ///   - progress: Optional continuation to receive progress updates.
    /// - Returns: (tempFileURL, fileIndex) pairs for each downloaded FIT file.
    ///   The caller must call `archiveFITFile(fileIndex:)` for each entry after
    ///   successfully persisting its content.
    func pullFITFiles(
        directories: Set<FITDirectory>,
        progress: AsyncStream<SyncProgress>.Continuation?
    ) async throws -> [(url: URL, fileIndex: UInt16)]

    /// Send the archive flag to the watch for one file after it has been
    /// successfully parsed and persisted.  No-op when not connected.
    func archiveFITFile(fileIndex: UInt16) async

    /// Upload a course FIT file to the connected device.
    /// - Parameter url: Local URL of the FIT file to upload.
    /// - Returns: The file index the watch assigned; store it for later presence checks.
    func uploadCourse(_ url: URL) async throws -> UInt16

    /// Whether a device is currently connected and authenticated.
    var isConnected: Bool { get async }

    /// A stream that emits a new value whenever the connection state changes.
    /// Callers subscribe once and observe for the lifetime of the session.
    func connectionStateStream() -> AsyncStream<ConnectionState>

    /// Send an arbitrary GFDI message to the connected device.
    /// Throws if not connected or the BLE write fails.
    func sendRaw(message: GFDIMessage) async throws

    /// Register a handler called with (url, fileIndex) pairs after a watch-initiated
    /// sync completes.  The default implementation is a no-op.
    func setWatchInitiatedSyncHandler(
        _ handler: (@Sendable ([(url: URL, fileIndex: UInt16)]) async -> Void)?
    ) async

    /// Cancel any in-flight sync task.
    func cancelSync() async

    /// Notify the watch that the app entered the background.
    func notifyBackground() async

    /// Notify the watch that the app returned to the foreground.
    func notifyForeground() async
}

extension DeviceManagerProtocol {
    public func setWatchInitiatedSyncHandler(
        _ handler: (@Sendable ([(url: URL, fileIndex: UInt16)]) async -> Void)?
    ) async {}
    public func archiveFITFile(fileIndex: UInt16) async {}
    public func cancelSync() async {}
    public func notifyBackground() async {}
    public func notifyForeground() async {}
}
