import Foundation
import os

/// A mock implementation of ``DeviceManagerProtocol`` for testing and simulator builds.
///
/// This actor simulates the full Garmin BLE protocol flow with realistic timing:
/// - Discovery yields a fake device after a short delay
/// - Pairing simulates the handshake with configurable delays
/// - File sync creates minimal synthetic FIT files
/// - Progress updates are reported through the continuation
///
/// Configure ``Configuration`` to control failure simulation.
///
/// Usage:
/// ```swift
/// let mock = MockGarminDevice()
/// for await device in mock.discover() {
///     let paired = try await mock.pair(device)
///     let files = try await mock.pullFITFiles(directories: [.activity], progress: nil)
/// }
/// ```
public actor MockGarminDevice: DeviceManagerProtocol {

    // MARK: - Configuration

    /// Configuration for the mock device behavior.
    public struct Configuration: Sendable {
        /// Whether discovery should fail (no devices found).
        public var failDiscovery: Bool

        /// Whether pairing should fail.
        public var failPairing: Bool

        /// Whether authentication should fail.
        public var failAuth: Bool

        /// Whether file sync should fail mid-transfer.
        public var failSync: Bool

        /// The simulated device name.
        public var deviceName: String

        /// The simulated device model.
        public var deviceModel: String

        /// Number of fake FIT files to generate per directory.
        public var filesPerDirectory: Int

        /// Size of each synthetic FIT file in bytes.
        public var fileSizeBytes: Int

        public init(
            failDiscovery: Bool = false,
            failPairing: Bool = false,
            failAuth: Bool = false,
            failSync: Bool = false,
            deviceName: String = "Forerunner 265",
            deviceModel: String = "Garmin Forerunner 265",
            filesPerDirectory: Int = 3,
            fileSizeBytes: Int = 4096
        ) {
            self.failDiscovery = failDiscovery
            self.failPairing = failPairing
            self.failAuth = failAuth
            self.failSync = failSync
            self.deviceName = deviceName
            self.deviceModel = deviceModel
            self.filesPerDirectory = filesPerDirectory
            self.fileSizeBytes = fileSizeBytes
        }
    }

    // MARK: - State

    private let config: Configuration
    private var _isConnected: Bool = false
    private let fakeIdentifier = UUID()

    // MARK: - Init

    /// Creates a mock device manager with the given configuration.
    /// - Parameter config: Configuration controlling mock behavior. Defaults to normal operation.
    public init(config: Configuration = Configuration()) {
        self.config = config
    }

    // MARK: - DeviceManagerProtocol

    public nonisolated func discover() -> AsyncStream<DiscoveredDevice> {
        let config = self.config
        let fakeIdentifier = self.fakeIdentifier

        return AsyncStream { continuation in
            let task = Task {
                BLELogger.transport.info("[Mock] Starting discovery")

                // Simulate BLE scanning delay
                try? await Task.sleep(for: .seconds(1))

                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }

                if config.failDiscovery {
                    BLELogger.transport.warning("[Mock] Discovery configured to fail — yielding no devices")
                    continuation.finish()
                    return
                }

                let device = DiscoveredDevice(
                    identifier: fakeIdentifier,
                    name: config.deviceName,
                    rssi: -55
                )

                BLELogger.transport.info("[Mock] Discovered device: \(device.name)")
                continuation.yield(device)

                // Keep the stream open briefly to simulate ongoing scanning
                try? await Task.sleep(for: .seconds(2))
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public func stopDiscovery() {
        BLELogger.transport.info("[Mock] Stopping discovery")
    }

    public func pair(_ device: DiscoveredDevice) async throws -> PairedDevice {
        BLELogger.auth.info("[Mock] Pairing with \(device.name)")

        if config.failPairing {
            BLELogger.auth.error("[Mock] Pairing configured to fail")
            throw PairingError.pairingRejected
        }

        // Simulate BLE connection time
        try await Task.sleep(for: .seconds(1))

        if config.failAuth {
            BLELogger.auth.error("[Mock] Authentication configured to fail")
            throw PairingError.authenticationFailed("Mock auth failure")
        }

        // Simulate authentication handshake
        try await Task.sleep(for: .milliseconds(500))

        _isConnected = true
        BLELogger.auth.info("[Mock] Pairing complete")

        return PairedDevice(
            identifier: device.identifier,
            name: device.name,
            model: config.deviceModel
        )
    }

    public func connect(_ device: PairedDevice) async throws {
        BLELogger.transport.info("[Mock] Connecting to \(device.name)")

        // Simulate reconnection
        try await Task.sleep(for: .milliseconds(800))

        _isConnected = true
        BLELogger.transport.info("[Mock] Connected")
    }

    public func disconnect() {
        BLELogger.transport.info("[Mock] Disconnecting")
        _isConnected = false
    }

    public func pullFITFiles(
        directories: Set<FITDirectory>,
        progress: AsyncStream<SyncProgress>.Continuation?
    ) async throws -> [URL] {
        BLELogger.sync.info("[Mock] Pulling FIT files from \(directories.count) directories")

        guard _isConnected else {
            let error = PairingError.bluetoothUnavailable
            progress?.yield(.failed(error))
            throw error
        }

        progress?.yield(.starting)

        var allURLs: [URL] = []
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompassBLE-Mock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        for directory in directories.sorted(by: { $0.rawValue < $1.rawValue }) {
            progress?.yield(.listing(directory: directory))

            // Simulate file listing delay
            try await Task.sleep(for: .milliseconds(300))

            if config.failSync {
                let error = PairingError.authenticationFailed("Mock sync failure during \(directory.rawValue)")
                progress?.yield(.failed(error))
                throw error
            }

            for fileIndex in 0..<config.filesPerDirectory {
                let fileName = "\(directory.rawValue)_\(fileIndex).fit"

                // Generate synthetic FIT file data
                let fitData = Self.generateSyntheticFIT(
                    directory: directory,
                    index: fileIndex,
                    size: config.fileSizeBytes
                )

                // Simulate chunked download with progress
                let chunkSize = 512
                var bytesReceived = 0
                while bytesReceived < fitData.count {
                    let nextChunk = min(chunkSize, fitData.count - bytesReceived)
                    bytesReceived += nextChunk

                    progress?.yield(.downloading(
                        file: fileName,
                        bytesReceived: bytesReceived,
                        totalBytes: fitData.count
                    ))

                    // Simulate BLE transfer time
                    try await Task.sleep(for: .milliseconds(50))
                }

                // Write to temp file
                let fileURL = tempDir.appendingPathComponent(fileName)
                try fitData.write(to: fileURL)
                allURLs.append(fileURL)
            }
        }

        progress?.yield(.parsing)
        try await Task.sleep(for: .milliseconds(200))

        progress?.yield(.completed(fileCount: allURLs.count))
        BLELogger.sync.info("[Mock] Pulled \(allURLs.count) files")

        return allURLs
    }

    public func uploadCourse(_ url: URL) async throws {
        BLELogger.sync.info("[Mock] Uploading course: \(url.lastPathComponent)")

        guard _isConnected else {
            throw PairingError.bluetoothUnavailable
        }

        // Simulate upload time
        try await Task.sleep(for: .seconds(2))
        BLELogger.sync.info("[Mock] Upload complete")
    }

    public var isConnected: Bool {
        _isConnected
    }

    public nonisolated func connectionStateStream() -> AsyncStream<ConnectionState> {
        AsyncStream { _ in }
    }

    public func sendRaw(message: GFDIMessage) async throws {
        BLELogger.gfdi.debug("[Mock] sendRaw type=0x\(String(format: "%04X", message.type.rawValue)) payload=\(message.payload.count)B")
    }

    // MARK: - Synthetic FIT Generation

    /// Generate a minimal synthetic FIT file.
    ///
    /// The FIT file format starts with a 14-byte header:
    /// - 1 byte: header size (14)
    /// - 1 byte: protocol version (0x20 = 2.0)
    /// - 2 bytes LE: profile version (0x0812 = 20.82)
    /// - 4 bytes LE: data size
    /// - 4 bytes: ".FIT" ASCII
    /// - 2 bytes: header CRC
    ///
    /// We generate the header and fill the rest with zeroed data records.
    /// This is enough for the app layer to recognize the file as FIT format,
    /// even though the data records are not valid.
    private static func generateSyntheticFIT(
        directory: FITDirectory,
        index: Int,
        size: Int
    ) -> Data {
        let headerSize: UInt8 = 14
        let protocolVersion: UInt8 = 0x20
        let profileVersion: UInt16 = 0x0812
        let dataSize = UInt32(max(0, size - 14))

        var data = Data(capacity: size)

        // FIT header
        data.append(headerSize)
        data.append(protocolVersion)
        data.append(UInt8(profileVersion & 0xFF))
        data.append(UInt8(profileVersion >> 8))
        data.append(UInt8(dataSize & 0xFF))
        data.append(UInt8((dataSize >> 8) & 0xFF))
        data.append(UInt8((dataSize >> 16) & 0xFF))
        data.append(UInt8((dataSize >> 24) & 0xFF))
        // ".FIT" signature
        data.append(contentsOf: [0x2E, 0x46, 0x49, 0x54])
        // Header CRC (zero for simplicity)
        data.append(contentsOf: [0x00, 0x00])

        // Fill remaining with tagged pseudo-data so files are distinguishable
        let tag = UInt8(directory.hashValue & 0xFF) ^ UInt8(index & 0xFF)
        let remaining = max(0, size - data.count)
        data.append(contentsOf: [UInt8](repeating: tag, count: remaining))

        return data
    }
}
