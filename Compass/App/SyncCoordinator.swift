import Foundation
import SwiftData
import UserNotifications
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

    // MARK: - Connection State

    var connectionState: ConnectionState = .disconnected

    // MARK: - Sync State

    var state: SyncState = .idle
    var lastSyncDate: Date?
    var progress: Double = 0

    let deviceManager: any DeviceManagerProtocol

    /// The last device we successfully connected to, kept for auto-reconnect.
    private var lastConnectedDevice: PairedDevice?
    private var discoveryTask: Task<Void, Never>?
    private var connectionMonitorTask: Task<Void, Never>?
    private var reconnectRetryTask: Task<Void, Never>?

    // MARK: - Watch Services

    private let weatherService       = WeatherService()
    private let findMyPhoneService   = FindMyPhoneService()
    private let musicService         = MusicService()
    private let phoneLocationService = PhoneLocationService()

    init(deviceManager: any DeviceManagerProtocol) {
        self.deviceManager = deviceManager
        AppLogger.sync.debug("SyncCoordinator initialized with \(String(describing: type(of: deviceManager)))")

        // Request notification permission (needed for Find My Phone banners).
        Task {
            try? await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound]
            )
        }

        // Monitor unexpected BLE drops and kick off auto-reconnect immediately
        // so CoreBluetooth re-establishes the link as soon as the watch is
        // reachable again (no polling delay for the common case).
        connectionMonitorTask = Task { [self] in
            for await state in deviceManager.connectionStateStream() {
                connectionState = state
                if case .disconnected = state {
                    tearDownDeviceCallbacks()
                    startAutoReconnect()
                }
            }
        }
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
                fitFileCursor: 0,
                peripheralIdentifier: pairedDevice.identifier
            )
            context.insert(connectedDevice)
            try? context.save()
            AppLogger.pairing.debug("Saved ConnectedDevice to SwiftData")

            lastConnectedDevice = pairedDevice
            connectionState = .connected(deviceName: pairedDevice.name)
            pairingState = .paired
            showPairingSheet = false

            await wireUpDeviceCallbacks()

            // Reset after brief delay so UI can show success
            try? await Task.sleep(for: .seconds(1))
            pairingState = .idle

        } catch {
            AppLogger.pairing.error("Pairing failed: \(error.localizedDescription)")
            pairingState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Reconnect / Remove

    /// Reconnect to a previously paired device on app launch.
    /// No-ops if already connecting or connected, or if the peripheral UUID was never stored.
    func reconnect(device: ConnectedDevice) async {
        guard case .disconnected = connectionState else { return }
        guard let peripheralID = device.peripheralIdentifier else {
            AppLogger.sync.warning("Cannot reconnect — no peripheral ID stored. Re-pair the device.")
            return
        }
        let paired = PairedDevice(identifier: peripheralID, name: device.name, model: device.model)
        lastConnectedDevice = paired
        await attemptConnect(paired)
    }

    /// Kick off a background reconnect loop that retries whenever the link is down.
    /// First attempt is immediate (0-delay) so CoreBluetooth can re-establish as
    /// soon as the watch becomes reachable; subsequent attempts back off to 15 s.
    private func startAutoReconnect() {
        guard lastConnectedDevice != nil else { return }
        reconnectRetryTask?.cancel()
        reconnectRetryTask = Task { [self] in
            var delay: Duration = .seconds(0)
            while !Task.isCancelled {
                if delay > .zero {
                    try? await Task.sleep(for: delay)
                }
                guard !Task.isCancelled else { break }
                guard case .disconnected = connectionState else { break }
                guard let device = lastConnectedDevice else { break }
                await attemptConnect(device)
                // If still disconnected after the attempt, back off before the next try.
                if case .disconnected = connectionState {
                    delay = .seconds(15)
                } else {
                    break
                }
            }
        }
    }

    /// Single connection attempt: sets connectionState and handles errors.
    private func attemptConnect(_ device: PairedDevice) async {
        AppLogger.sync.info("Connecting to \(device.name)")
        connectionState = .connecting
        do {
            try await deviceManager.connect(device)
            connectionState = .connected(deviceName: device.name)
            await wireUpDeviceCallbacks()
        } catch {
            AppLogger.sync.error("Connect failed: \(error.localizedDescription)")
            connectionState = .disconnected
        }
    }

    /// Disconnect and delete the paired device record from SwiftData.
    func removeDevice(_ device: ConnectedDevice, context: ModelContext) async {
        AppLogger.pairing.info("Removing paired device: \(device.name)")
        reconnectRetryTask?.cancel()
        reconnectRetryTask = nil
        lastConnectedDevice = nil
        await deviceManager.disconnect()
        connectionState = .disconnected
        context.delete(device)
        try? context.save()
    }

    // MARK: - Watch Service Wiring

    /// Inject service callbacks into GarminDeviceManager after a successful connect.
    /// Must be called on @MainActor (this class is @MainActor).
    private func wireUpDeviceCallbacks() async {
        guard let gm = deviceManager as? GarminDeviceManager else { return }

        await gm.setWeatherProvider { [weak self] request in
            guard let self else { throw CancellationError() }
            return try await self.weatherService.buildFITMessages(for: request)
        }

        await gm.setMusicCommandHandler { [weak self] ordinal in
            Task { @MainActor [weak self] in
                self?.musicService.handleCommand(ordinal: ordinal)
            }
        }

        await gm.setFindMyPhoneHandler { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.findMyPhoneService.handle(event)
            }
        }

        // Capture gm directly so the closure avoids the protocol cast on every call.
        musicService.startObserving { [weak gm] messages in
            Task { [weak gm] in
                await gm?.sendMusicEntityUpdate(messages)
            }
        }
        // Push current now-playing state immediately so the watch face
        // populates without waiting for a playback-state change.
        musicService.pushCurrentState()

        phoneLocationService.sendMessage = { [weak gm] msg in
            try? await gm?.sendRaw(message: msg)
        }
        phoneLocationService.startUpdating()

        AppLogger.sync.info("Watch services wired: weather, find-my-phone, music, phone-location")
    }

    private func tearDownDeviceCallbacks() {
        Task {
            guard let gm = deviceManager as? GarminDeviceManager else { return }
            await gm.setWeatherProvider(nil)
            await gm.setMusicCommandHandler(nil)
            await gm.setFindMyPhoneHandler(nil)
        }
        musicService.stopObserving()
        phoneLocationService.stopUpdating()
        phoneLocationService.sendMessage = nil
        AppLogger.sync.info("Watch services torn down")
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
                        // Dedup: skip if an activity with the same start date already exists
                        let activityStart = activity.startDate
                        var activityCheck = FetchDescriptor<Activity>(
                            predicate: #Predicate<Activity> { act in
                                act.startDate == activityStart
                            }
                        )
                        activityCheck.fetchLimit = 1
                        let existingActivities = (try? context.fetch(activityCheck)) ?? []
                        guard existingActivities.isEmpty else {
                            AppLogger.sync.debug("Skipping duplicate activity at \(activity.startDate)")
                            continue
                        }
                        context.insert(activity)
                        AppLogger.sync.debug("Inserted activity: \(activity.sport.displayName)")
                    }
                } else if filename.contains("monitor") || filename.contains("mon") {
                    let parser = MonitoringFITParser()
                    if let results = try? await parser.parse(data: fileData) {
                        // HR samples — file-range dedup: skip if any HR exists in this file's span
                        if !results.heartRateSamples.isEmpty {
                            let firstTS = results.heartRateSamples.first!.timestamp
                            let lastTS = results.heartRateSamples.last!.timestamp
                            var hrCheck = FetchDescriptor<HeartRateSample>(
                                predicate: #Predicate<HeartRateSample> { hr in
                                    hr.timestamp >= firstTS && hr.timestamp <= lastTS
                                }
                            )
                            hrCheck.fetchLimit = 1
                            let existingHR = (try? context.fetch(hrCheck)) ?? []
                            if existingHR.isEmpty {
                                for sample in results.heartRateSamples {
                                    context.insert(HeartRateSample(timestamp: sample.timestamp, bpm: sample.bpm, context: .resting))
                                }
                            }
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
                        // Day-aggregate monitoring intervals into one StepCount per calendar day
                        let calendar = Calendar.current
                        var dayIntervals: [Date: [MonitoringInterval]] = [:]
                        for interval in results.intervals {
                            let dayStart = calendar.startOfDay(for: interval.timestamp)
                            dayIntervals[dayStart, default: []].append(interval)
                        }
                        var insertedDays = 0
                        for (day, dayData) in dayIntervals {
                            let daySteps = dayData.reduce(0) { $0 + $1.steps }
                            let dayIntensityMinutes = dayData.reduce(0) { $0 + $1.intensityMinutes }
                            let dayCalories = dayData.reduce(0.0) { $0 + $1.activeCalories }
                            // Upsert: update existing record for this day if present
                            let dayDate = day
                            var stepCheck = FetchDescriptor<CompassData.StepCount>(
                                predicate: #Predicate<CompassData.StepCount> { count in
                                    count.date == dayDate
                                }
                            )
                            stepCheck.fetchLimit = 1
                            let existingCounts = (try? context.fetch(stepCheck)) ?? []
                            if let existing = existingCounts.first {
                                existing.steps = daySteps
                                existing.intensityMinutes = dayIntensityMinutes
                                existing.calories = dayCalories
                            } else {
                                context.insert(CompassData.StepCount(date: day, steps: daySteps, intensityMinutes: dayIntensityMinutes, calories: dayCalories))
                                insertedDays += 1
                            }
                        }
                        AppLogger.sync.debug("Inserted monitoring data: \(results.heartRateSamples.count) HR, \(results.stressSamples.count) stress, \(results.bodyBatterySamples.count) BB, \(results.respirationSamples.count) resp, \(results.intervals.count) intervals → \(insertedDays) day(s)")
                    }
                } else if filename.contains("sleep") || filename.contains("slp") {
                    let parser = SleepFITParser()
                    if let result = try? await parser.parse(data: fileData) {
                        // Dedup: skip if a session exists with startDate within ±1 hour
                        let lowerBound = result.startDate.addingTimeInterval(-3600)
                        let upperBound = result.startDate.addingTimeInterval(3600)
                        var sleepCheck = FetchDescriptor<SleepSession>(
                            predicate: #Predicate<SleepSession> { s in
                                s.startDate >= lowerBound && s.startDate <= upperBound
                            }
                        )
                        sleepCheck.fetchLimit = 1
                        let existingSessions = (try? context.fetch(sleepCheck)) ?? []
                        guard existingSessions.isEmpty else {
                            AppLogger.sync.debug("Skipping duplicate sleep session near \(result.startDate)")
                            continue
                        }
                        let session = SleepSession(
                            id: UUID(),
                            startDate: result.startDate,
                            endDate: result.endDate,
                            score: result.score,
                            recoveryScore: result.recoveryScore,
                            qualifier: result.qualifier
                        )
                        context.insert(session)
                        for stageResult in result.stages {
                            let stage = SleepStage(
                                startDate: stageResult.startDate,
                                endDate: stageResult.endDate,
                                stage: stageResult.stage,
                                session: session
                            )
                            context.insert(stage)
                        }
                        AppLogger.sync.debug("Inserted sleep session: \(result.startDate) – \(result.endDate) with \(result.stages.count) stage(s)")
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
