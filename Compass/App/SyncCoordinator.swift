import Foundation
import SwiftData
import CompassData
import CompassBLE
import CompassFIT

@Observable
@MainActor
final class SyncCoordinator {
    enum SyncState: Equatable {
        case idle
        case syncing(description: String)
        case completed(fileCount: Int)
        case failed(String)

        // Custom Equatable since Error isn't Equatable
        static func == (lhs: SyncState, rhs: SyncState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): true
            case (.syncing(let a), .syncing(let b)): a == b
            case (.completed(let a), .completed(let b)): a == b
            case (.failed(let a), .failed(let b)): a == b
            default: false
            }
        }
    }

    // MARK: - Pairing State

    enum PairingState: Equatable {
        case idle
        case scanning
        case pairing(deviceName: String)
        case paired
        case failed(String)
    }

    var pairingState: PairingState = .idle
    var discoveredDevices: [DiscoveredDevice] = []
    var showPairingSheet = false

    // MARK: - Sync State

    var state: SyncState = .idle
    var lastSyncDate: Date?
    var progress: Double = 0

    let deviceManager: any DeviceManagerProtocol

    private var discoveryTask: Task<Void, Never>?

    init(deviceManager: any DeviceManagerProtocol) {
        self.deviceManager = deviceManager
        AppLogger.sync.debug("SyncCoordinator initialized with \(String(describing: type(of: deviceManager)))")
    }

    // MARK: - Pairing

    func startPairing() {
        AppLogger.pairing.info("Starting pairing flow")
        pairingState = .scanning
        discoveredDevices = []
        showPairingSheet = true

        discoveryTask?.cancel()
        discoveryTask = Task {
            AppLogger.pairing.debug("Beginning device discovery stream")
            let stream = deviceManager.discover()
            for await device in stream {
                guard !Task.isCancelled else {
                    AppLogger.pairing.debug("Discovery task cancelled")
                    break
                }
                AppLogger.pairing.info("Discovered device: \(device.name) (RSSI: \(device.rssi), id: \(device.identifier))")
                if !discoveredDevices.contains(where: { $0.identifier == device.identifier }) {
                    discoveredDevices.append(device)
                    AppLogger.pairing.debug("Device list now has \(self.discoveredDevices.count) device(s)")
                }
            }
            AppLogger.pairing.debug("Discovery stream ended")
        }
    }

    func cancelPairing() {
        AppLogger.pairing.info("Cancelling pairing flow")
        discoveryTask?.cancel()
        discoveryTask = nil
        Task {
            await deviceManager.stopDiscovery()
        }
        pairingState = .idle
        discoveredDevices = []
        showPairingSheet = false
    }

    func pairDevice(_ device: DiscoveredDevice, context: ModelContext) async {
        AppLogger.pairing.info("Pairing with device: \(device.name) (\(device.identifier))")
        pairingState = .pairing(deviceName: device.name)

        // Stop discovery while pairing
        discoveryTask?.cancel()
        discoveryTask = nil
        await deviceManager.stopDiscovery()
        AppLogger.pairing.debug("Discovery stopped for pairing")

        do {
            let pairedDevice = try await deviceManager.pair(device)
            AppLogger.pairing.info("Pairing succeeded: \(pairedDevice.name), model: \(pairedDevice.model ?? "unknown")")

            // Save to SwiftData
            let connectedDevice = ConnectedDevice(
                name: pairedDevice.name,
                model: pairedDevice.model ?? "Unknown",
                lastSyncedAt: nil,
                fitFileCursor: 0
            )
            context.insert(connectedDevice)
            try? context.save()
            AppLogger.pairing.debug("Saved ConnectedDevice to SwiftData")

            pairingState = .paired
            showPairingSheet = false

            // Reset after brief delay so UI can show success
            try? await Task.sleep(for: .seconds(1))
            pairingState = .idle

        } catch {
            AppLogger.pairing.error("Pairing failed: \(error.localizedDescription)")
            pairingState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Sync

    func sync(context: ModelContext) async {
        guard case .idle = state else {
            AppLogger.sync.warning("Sync requested but already in state: \(String(describing: self.state))")
            return
        }

        AppLogger.sync.info("Starting sync")
        state = .syncing(description: "Starting sync...")

        do {
            // Create progress stream
            let (stream, continuation) = AsyncStream<SyncProgress>.makeStream()

            // Monitor progress in background
            let progressTask = Task {
                for await progressUpdate in stream {
                    AppLogger.sync.debug("Progress: \(progressUpdate.description)")
                    await MainActor.run {
                        switch progressUpdate {
                        case .starting:
                            self.state = .syncing(description: "Connecting...")
                        case .listing(let dir):
                            self.state = .syncing(description: "Listing \(dir) files...")
                        case .downloading(let file, let received, let total):
                            let totalStr = total.map { " / \($0)" } ?? ""
                            self.state = .syncing(description: "Downloading \(file): \(received)\(totalStr) bytes")
                            if let total, total > 0 {
                                self.progress = Double(received) / Double(total)
                            }
                        case .parsing:
                            self.state = .syncing(description: "Parsing data...")
                        case .completed(let count):
                            self.state = .completed(fileCount: count)
                        case .failed(let error):
                            self.state = .failed(error.localizedDescription)
                        }
                    }
                }
            }

            // Pull FIT files
            let directories: Set<FITDirectory> = [.activity, .monitor, .sleep, .metrics]
            AppLogger.sync.debug("Requesting FIT files from directories: \(directories.map(\.rawValue).joined(separator: ", "))")
            let fitURLs = try await deviceManager.pullFITFiles(
                directories: directories,
                progress: continuation
            )
            continuation.finish()
            progressTask.cancel()

            AppLogger.sync.info("Received \(fitURLs.count) FIT file(s), beginning parse")

            // Parse FIT files and write to SwiftData
            state = .syncing(description: "Parsing \(fitURLs.count) files...")

            for url in fitURLs {
                guard let fileData = try? Data(contentsOf: url) else {
                    AppLogger.sync.warning("Could not read FIT file at: \(url.lastPathComponent)")
                    continue
                }
                let filename = url.lastPathComponent.lowercased()
                AppLogger.sync.debug("Parsing file: \(filename) (\(fileData.count) bytes)")

                if filename.contains("activity") || filename.contains("act") {
                    let parser = ActivityFITParser()
                    if let activity = try? await parser.parse(data: fileData) {
                        context.insert(activity)
                        AppLogger.sync.debug("Inserted activity: \(activity.sport.displayName)")
                    }
                } else if filename.contains("monitor") || filename.contains("mon") {
                    let parser = MonitoringFITParser()
                    if let results = try? await parser.parse(data: fileData) {
                        for sample in results.heartRateSamples {
                            context.insert(HeartRateSample(timestamp: sample.timestamp, bpm: sample.bpm, context: .resting))
                        }
                        for sample in results.stressSamples {
                            context.insert(StressSample(timestamp: sample.timestamp, stressScore: sample.stressScore))
                        }
                        for sample in results.bodyBatterySamples {
                            context.insert(CompassData.BodyBatterySample(timestamp: sample.timestamp, level: sample.level))
                        }
                        for sample in results.respirationSamples {
                            context.insert(CompassData.RespirationSample(timestamp: sample.timestamp, breathsPerMinute: sample.breathsPerMinute))
                        }
                        for count in results.stepCounts {
                            context.insert(CompassData.StepCount(date: count.timestamp, steps: count.steps, intensityMinutes: 0, calories: 0))
                        }
                        AppLogger.sync.debug("Inserted monitoring data: \(results.heartRateSamples.count) HR, \(results.stressSamples.count) stress, \(results.bodyBatterySamples.count) BB, \(results.respirationSamples.count) resp, \(results.stepCounts.count) steps")
                    }
                } else if filename.contains("sleep") || filename.contains("slp") {
                    let parser = SleepFITParser()
                    if let result = try? await parser.parse(data: fileData) {
                        let session = SleepSession(
                            id: UUID(),
                            startDate: result.startDate,
                            endDate: result.endDate,
                            score: result.score
                        )
                        context.insert(session)
                        AppLogger.sync.debug("Inserted sleep session: \(result.startDate) - \(result.endDate)")
                    }
                } else if filename.contains("metric") || filename.contains("met") {
                    let parser = MetricsFITParser()
                    if let results = try? await parser.parse(data: fileData) {
                        for sample in results {
                            context.insert(HRVSample(timestamp: sample.timestamp, rmssd: sample.rmssd, context: .resting))
                        }
                        AppLogger.sync.debug("Inserted \(results.count) HRV samples")
                    }
                } else {
                    AppLogger.sync.warning("Unrecognized FIT filename pattern: \(filename)")
                }
            }

            try? context.save()
            AppLogger.sync.info("SwiftData save complete")

            lastSyncDate = Date()
            state = .completed(fileCount: fitURLs.count)
            AppLogger.sync.info("Sync completed: \(fitURLs.count) files processed")

            // Reset to idle after a delay
            try? await Task.sleep(for: .seconds(3))
            state = .idle

        } catch {
            AppLogger.sync.error("Sync failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
            try? await Task.sleep(for: .seconds(5))
            state = .idle
        }
    }
}
