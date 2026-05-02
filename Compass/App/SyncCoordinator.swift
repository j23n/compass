import Foundation
import SwiftData
import SwiftUI
import UIKit
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
    private let modelContainer: ModelContainer

    /// The last device we successfully connected to, kept for auto-reconnect.
    private var lastConnectedDevice: PairedDevice?
    private var discoveryTask: Task<Void, Never>?
    private var connectionMonitorTask: Task<Void, Never>?
    private var reconnectRetryTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var bgTaskID: UIBackgroundTaskIdentifier = .invalid

    // MARK: - Watch Services

    private let weatherService       = WeatherService()
    private let findMyPhoneService   = FindMyPhoneService()
    private let musicService         = MusicService()
    private let phoneLocationService = PhoneLocationService()

    init(deviceManager: any DeviceManagerProtocol, modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
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
        connectionState = .reconnecting
        do {
            try await deviceManager.connect(device)
            connectionState = .connected(deviceName: device.name)
            await wireUpDeviceCallbacks()
        } catch {
            AppLogger.sync.error("Connect failed: \(error.localizedDescription)")
            connectionState = .disconnected
        }
    }

    func manualDisconnect() async {
        reconnectRetryTask?.cancel()
        reconnectRetryTask = nil
        await deviceManager.disconnect()
        connectionState = .disconnected
        AppLogger.sync.info("Manual disconnect")
        // lastConnectedDevice preserved — user can reconnect
    }

    func manualReconnect() {
        guard lastConnectedDevice != nil else { return }
        startAutoReconnect()
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

    // MARK: - Sync Control

    func cancelSync() {
        syncTask?.cancel()
        syncTask = nil
        state = .idle
        progress = 0
        AppLogger.sync.info("Sync cancelled by user")
        Task { await deviceManager.cancelSync() }
    }

    // MARK: - Background Execution

    private func beginBackgroundTask() {
        guard bgTaskID == .invalid else { return }
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "com.compass.sync") { [weak self] in
            self?.cancelSync()
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard bgTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTaskID)
        bgTaskID = .invalid
    }

    func handleScenePhase(_ phase: ScenePhase) async {
        switch phase {
        case .background:
            await deviceManager.notifyBackground()
        case .active:
            await deviceManager.notifyForeground()
            if case .disconnected = connectionState {
                startAutoReconnect()
            }
        default:
            break
        }
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

        await gm.setWatchInitiatedSyncHandler { [weak self] urls in
            guard let self else { return }
            await self.processWatchInitiatedURLs(urls)
        }

        AppLogger.sync.info("Watch services wired: weather, find-my-phone, music, phone-location")
    }

    private func tearDownDeviceCallbacks() {
        Task {
            guard let gm = deviceManager as? GarminDeviceManager else { return }
            await gm.setWeatherProvider(nil)
            await gm.setMusicCommandHandler(nil)
            await gm.setFindMyPhoneHandler(nil)
            await gm.setWatchInitiatedSyncHandler(nil)
        }
        musicService.stopObserving()
        phoneLocationService.stopUpdating()
        phoneLocationService.sendMessage = nil
        AppLogger.sync.info("Watch services torn down")
    }

    // MARK: - Sync

    func sync(context: ModelContext) {
        guard case .idle = state else {
            AppLogger.sync.warning("Sync requested but already in state: \(String(describing: self.state))")
            return
        }

        deduplicateStepSamplesIfNeeded(context: context)
        AppLogger.sync.info("Starting sync")
        state = .syncing(description: "Starting sync...")

        syncTask = Task {
            self.beginBackgroundTask()
            defer { self.endBackgroundTask() }
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

            state = .syncing(description: "Parsing \(fitURLs.count) files...")
            let count = await processFITFiles(fitURLs, context: context)

            state = .completed(fileCount: count)
            AppLogger.sync.info("Sync completed: \(count) files processed")

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

    @discardableResult
    private func processFITFiles(_ urls: [URL], context: ModelContext) async -> Int {
        var savedURLs: [URL] = []
        for url in urls {
            if let saved = try? FITFileStore.shared.save(from: url) {
                savedURLs.append(saved)
                AppLogger.sync.debug("Saved FIT file: \(saved.lastPathComponent)")
            } else {
                AppLogger.sync.warning("Failed to save FIT file: \(url.lastPathComponent)")
            }
        }

        for url in savedURLs {
            guard let fileData = try? Data(contentsOf: url) else {
                AppLogger.sync.warning("Could not read FIT file at: \(url.lastPathComponent)")
                continue
            }
            let filename = url.lastPathComponent.lowercased()
            AppLogger.sync.debug("Parsing file: \(filename) (\(fileData.count) bytes)")

            if filename.contains("activity") || filename.contains("act") {
                let parser = ActivityFITParser()
                if let activity = try? await parser.parse(data: fileData) {
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
                    activity.sourceFileName = url.lastPathComponent
                    context.insert(activity)
                    AppLogger.sync.debug("Inserted activity: \(activity.sport.displayName)")
                }
            } else if filename.contains("monitor") || filename.contains("mon") {
                let parser = MonitoringFITParser()
                if let results = try? await parser.parse(data: fileData) {
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
                    let calendar = Calendar.current
                    var dayIntervals: [Date: [MonitoringInterval]] = [:]
                    for interval in results.intervals {
                        let dayStart = calendar.startOfDay(for: interval.timestamp)
                        dayIntervals[dayStart, default: []].append(interval)
                    }
                    if !results.intervals.isEmpty {
                        let firstTS = results.intervals.first!.timestamp
                        let lastTS  = results.intervals.last!.timestamp
                        var stepSampleCheck = FetchDescriptor<CompassData.StepSample>(
                            predicate: #Predicate<CompassData.StepSample> { s in
                                s.timestamp >= firstTS && s.timestamp <= lastTS
                            }
                        )
                        stepSampleCheck.fetchLimit = 1
                        let existingStepSamples = (try? context.fetch(stepSampleCheck)) ?? []
                        if existingStepSamples.isEmpty {
                            for interval in results.intervals where interval.steps > 0 {
                                context.insert(CompassData.StepSample(
                                    timestamp: interval.timestamp,
                                    steps: interval.steps
                                ))
                            }
                        }
                    }
                    var insertedDays = 0
                    for (day, dayData) in dayIntervals {
                        let daySteps = dayData.reduce(0) { $0 + $1.steps }
                        let dayIntensityMinutes = dayData.reduce(0) { $0 + $1.intensityMinutes }
                        let dayCalories = dayData.reduce(0.0) { $0 + $1.activeCalories }
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
        return savedURLs.count
    }

    private func processWatchInitiatedURLs(_ urls: [URL]) async {
        beginBackgroundTask()
        defer { endBackgroundTask() }
        let context = ModelContext(modelContainer)
        await processFITFiles(urls, context: context)
    }

    /// - Parameter fitSize: Byte count of the encoded FIT — stored as a stable watch-side identifier.
    func uploadCourse(fitURL: URL, fitSize: Int, course: Course) {
        guard case .idle = state else {
            AppLogger.sync.warning("Upload requested but already in state: \(String(describing: self.state))")
            return
        }

        AppLogger.sync.info("Starting course upload")
        state = .syncing(description: "Uploading course...")

        do {
            let staged = try CourseFileStore.shared.save(from: fitURL)
            AppLogger.sync.info("Staged course FIT for inspection: \(staged.lastPathComponent)")
        } catch {
            AppLogger.sync.warning("Failed to stage course FIT: \(error.localizedDescription)")
        }

        syncTask = Task {
            do {
                let fileIndex = try await deviceManager.uploadCourse(fitURL)
                AppLogger.sync.info("Course uploaded successfully (fileIndex=\(fileIndex), size=\(fitSize)B)")
                course.uploadedToWatch = true
                course.lastUploadDate = Date()
                course.watchFITSize = fitSize
                state = .completed(fileCount: 1)

                try? await Task.sleep(for: .seconds(3))
                state = .idle

            } catch {
                AppLogger.sync.error("Upload failed: \(error.localizedDescription)")
                state = .failed(error.localizedDescription)
                try? await Task.sleep(for: .seconds(5))
                state = .idle
            }
        }
    }

    // MARK: - Data hygiene

    /// Removes duplicate StepSample rows (same timestamp) accumulated before per-timestamp dedup
    /// was introduced. Runs once, guarded by a UserDefaults flag.
    private func deduplicateStepSamplesIfNeeded(context: ModelContext) {
        let key = "stepSamplesDeduped_v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        let all = (try? context.fetch(FetchDescriptor<CompassData.StepSample>(
            sortBy: [SortDescriptor(\.timestamp)]
        ))) ?? []

        var seen: [TimeInterval: CompassData.StepSample] = [:]
        var duplicates: [CompassData.StepSample] = []
        for sample in all {
            let key = sample.timestamp.timeIntervalSince1970
            if seen[key] != nil {
                duplicates.append(sample)
            } else {
                seen[key] = sample
            }
        }

        if !duplicates.isEmpty {
            duplicates.forEach { context.delete($0) }
            try? context.save()
            AppLogger.sync.info("Deduplication: removed \(duplicates.count) duplicate StepSample rows")
        }

        UserDefaults.standard.set(true, forKey: "stepSamplesDeduped_v1")
    }

    /// Check whether the course's file is still present on the watch.
    /// Matches by FIT byte size, which is stable even after the watch renames/reindexes the file.
    /// Returns `nil` if not connected or the directory query failed.
    func checkCourseOnWatch(course: Course) async -> Bool? {
        guard case .connected = connectionState else { return nil }
        guard let fitSize = course.watchFITSize else { return nil }
        do {
            let files = try await deviceManager.listCourseFiles()
            let found = files.contains { Int($0.size) == fitSize }
            if !found { course.uploadedToWatch = false }
            return found
        } catch {
            AppLogger.sync.warning("Course presence check failed: \(error.localizedDescription)")
            return nil
        }
    }
}
