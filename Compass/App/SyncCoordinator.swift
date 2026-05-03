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

    /// Device profile derived from the paired device's product ID.
    private var deviceProfile: DeviceProfile = .default

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

        Task {
            try? await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound]
            )
        }

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

        discoveryTask?.cancel()
        discoveryTask = nil
        await deviceManager.stopDiscovery()
        AppLogger.pairing.debug("Discovery stopped for pairing")

        do {
            let pairedDevice = try await deviceManager.pair(device)
            AppLogger.pairing.info("Pairing succeeded: \(pairedDevice.name), model: \(pairedDevice.model ?? "unknown")")

            let connectedDevice = ConnectedDevice(
                name: pairedDevice.name,
                model: pairedDevice.model ?? "Unknown",
                productID: pairedDevice.productID,
                lastSyncedAt: nil,
                fitFileCursor: 0,
                peripheralIdentifier: pairedDevice.identifier
            )
            context.insert(connectedDevice)
            try? context.save()
            AppLogger.pairing.debug("Saved ConnectedDevice to SwiftData")

            lastConnectedDevice = pairedDevice
            deviceProfile = DeviceProfile.profile(for: pairedDevice.productID)
            connectionState = .connected(deviceName: pairedDevice.name)
            pairingState = .paired
            showPairingSheet = false

            await wireUpDeviceCallbacks()

            try? await Task.sleep(for: .seconds(1))
            pairingState = .idle

        } catch {
            AppLogger.pairing.error("Pairing failed: \(error.localizedDescription)")
            pairingState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Reconnect / Remove

    func reconnect(device: ConnectedDevice) async {
        guard case .disconnected = connectionState else { return }
        guard let peripheralID = device.peripheralIdentifier else {
            AppLogger.sync.warning("Cannot reconnect — no peripheral ID stored. Re-pair the device.")
            return
        }
        let paired = PairedDevice(identifier: peripheralID, name: device.name, model: device.model, productID: device.productID ?? 0)
        lastConnectedDevice = paired
        deviceProfile = DeviceProfile.profile(for: device.productID ?? 0)
        await attemptConnect(paired)
    }

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
                if case .disconnected = connectionState {
                    delay = .seconds(15)
                } else {
                    break
                }
            }
        }
    }

    private func attemptConnect(_ device: PairedDevice) async {
        AppLogger.sync.info("Connecting to \(device.name)")
        connectionState = .reconnecting
        do {
            try await deviceManager.connect(device)
            connectionState = .connected(deviceName: device.name)
            deviceProfile = DeviceProfile.profile(for: device.productID)
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
    }

    func manualReconnect() {
        guard lastConnectedDevice != nil else { return }
        startAutoReconnect()
    }

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

        musicService.startObserving { [weak gm] messages in
            Task { [weak gm] in
                await gm?.sendMusicEntityUpdate(messages)
            }
        }
        musicService.pushCurrentState()

        phoneLocationService.sendMessage = { [weak gm] msg in
            try? await gm?.sendRaw(message: msg)
        }
        phoneLocationService.startUpdating()

        await gm.setWatchInitiatedSyncHandler { [weak self] entries in
            guard let self else { return }
            await self.processWatchInitiatedURLs(entries)
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
            let (stream, continuation) = AsyncStream<SyncProgress>.makeStream()

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

            let directories: Set<FITDirectory> = [.activity, .monitor, .sleep, .metrics]
            AppLogger.sync.debug("Requesting FIT files from directories: \(directories.map(\.rawValue).joined(separator: ", "))")
            let fitEntries = try await deviceManager.pullFITFiles(
                directories: directories,
                progress: continuation
            )
            continuation.finish()
            progressTask.cancel()

            AppLogger.sync.info("Received \(fitEntries.count) FIT file(s), beginning parse")

            state = .syncing(description: "Parsing \(fitEntries.count) files...")
            let count = await processFITFiles(fitEntries, context: context)

            state = .completed(fileCount: count)
            AppLogger.sync.info("Sync completed: \(count) files processed")

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
    private func processFITFiles(
        _ entries: [(url: URL, fileIndex: UInt16)],
        context: ModelContext
    ) async -> Int {
        var savedEntries: [(url: URL, fileIndex: UInt16)] = []
        for entry in entries {
            if let saved = try? FITFileStore.shared.save(from: entry.url) {
                savedEntries.append((url: saved, fileIndex: entry.fileIndex))
                AppLogger.sync.debug("Saved FIT file: \(saved.lastPathComponent)")
            } else {
                AppLogger.sync.warning("Failed to save FIT file: \(entry.url.lastPathComponent)")
            }
        }

        for savedEntry in savedEntries {
            let url = savedEntry.url
            let fileIndex = savedEntry.fileIndex

            guard let fileData = try? Data(contentsOf: url) else {
                AppLogger.sync.warning("Could not read FIT file at: \(url.lastPathComponent)")
                continue
            }
            let filename = url.lastPathComponent.lowercased()
            AppLogger.sync.debug("Parsing file: \(filename) (\(fileData.count) bytes)")

            var parsedOK = false

            if filename.contains("activity") || filename.contains("act") {
                let parser = ActivityFITParser()
                do {
                    if let activity = try await parser.parse(data: fileData) {
                        parsedOK = true
                        let activityStart = activity.startDate
                        var activityCheck = FetchDescriptor<Activity>(
                            predicate: #Predicate<Activity> { act in
                                act.startDate == activityStart
                            }
                        )
                        activityCheck.fetchLimit = 1
                        let existingActivities = (try? context.fetch(activityCheck)) ?? []
                        if existingActivities.isEmpty {
                            activity.sourceFileName = url.lastPathComponent
                            context.insert(activity)
                            AppLogger.sync.debug("Inserted activity: \(activity.sport.displayName)")
                        } else {
                            AppLogger.sync.debug("Skipping duplicate activity at \(activity.startDate)")
                        }
                    }
                } catch {
                    AppLogger.sync.error("Activity parse failed for \(filename): \(error.localizedDescription)")
                }
            } else if filename.contains("monitor") || filename.contains("mon") {
                let parser = MonitoringFITParser(profile: deviceProfile)
                do {
                    let results = try await parser.parse(data: fileData)
                    parsedOK = true
                    if !results.heartRateSamples.isEmpty {
                        let firstTS = results.heartRateSamples.first!.timestamp
                        let lastTS  = results.heartRateSamples.last!.timestamp
                        let existingHRTimes: Set<Date> = {
                            let d = FetchDescriptor<HeartRateSample>(
                                predicate: #Predicate<HeartRateSample> { hr in
                                    hr.timestamp >= firstTS && hr.timestamp <= lastTS
                                }
                            )
                            return Set(((try? context.fetch(d)) ?? []).map(\.timestamp))
                        }()
                        for sample in results.heartRateSamples where !existingHRTimes.contains(sample.timestamp) {
                            context.insert(HeartRateSample(timestamp: sample.timestamp, bpm: sample.bpm, context: .unspecified))
                        }
                    }
                    if !results.stressSamples.isEmpty {
                        let firstTS = results.stressSamples.first!.timestamp
                        let lastTS  = results.stressSamples.last!.timestamp
                        let existingTimes: Set<Date> = {
                            let d = FetchDescriptor<StressSample>(
                                predicate: #Predicate<StressSample> { s in
                                    s.timestamp >= firstTS && s.timestamp <= lastTS
                                }
                            )
                            return Set(((try? context.fetch(d)) ?? []).map(\.timestamp))
                        }()
                        for sample in results.stressSamples where !existingTimes.contains(sample.timestamp) {
                            context.insert(StressSample(timestamp: sample.timestamp, stressScore: sample.stressScore))
                        }
                    }
                    if !results.bodyBatterySamples.isEmpty {
                        let firstTS = results.bodyBatterySamples.first!.timestamp
                        let lastTS  = results.bodyBatterySamples.last!.timestamp
                        let existingTimes: Set<Date> = {
                            let d = FetchDescriptor<CompassData.BodyBatterySample>(
                                predicate: #Predicate<CompassData.BodyBatterySample> { b in
                                    b.timestamp >= firstTS && b.timestamp <= lastTS
                                }
                            )
                            return Set(((try? context.fetch(d)) ?? []).map(\.timestamp))
                        }()
                        for sample in results.bodyBatterySamples where !existingTimes.contains(sample.timestamp) {
                            context.insert(CompassData.BodyBatterySample(timestamp: sample.timestamp, level: sample.level))
                        }
                    }
                    if !results.respirationSamples.isEmpty {
                        let firstTS = results.respirationSamples.first!.timestamp
                        let lastTS  = results.respirationSamples.last!.timestamp
                        let existingTimes: Set<Date> = {
                            let d = FetchDescriptor<CompassData.RespirationSample>(
                                predicate: #Predicate<CompassData.RespirationSample> { r in
                                    r.timestamp >= firstTS && r.timestamp <= lastTS
                                }
                            )
                            return Set(((try? context.fetch(d)) ?? []).map(\.timestamp))
                        }()
                        for sample in results.respirationSamples where !existingTimes.contains(sample.timestamp) {
                            context.insert(CompassData.RespirationSample(timestamp: sample.timestamp, breathsPerMinute: sample.breathsPerMinute))
                        }
                    }
                    if !results.spo2Samples.isEmpty {
                        let firstTS = results.spo2Samples.first!.timestamp
                        let lastTS  = results.spo2Samples.last!.timestamp
                        let existingTimes: Set<Date> = {
                            let d = FetchDescriptor<SpO2Sample>(
                                predicate: #Predicate<SpO2Sample> { s in
                                    s.timestamp >= firstTS && s.timestamp <= lastTS
                                }
                            )
                            return Set(((try? context.fetch(d)) ?? []).map(\.timestamp))
                        }()
                        for sample in results.spo2Samples where !existingTimes.contains(sample.timestamp) {
                            context.insert(SpO2Sample(timestamp: sample.timestamp, percent: sample.percent))
                        }
                    }
                    let calendar = Calendar.current
                    var dayIntervals: [Date: [MonitoringInterval]] = [:]
                    for interval in results.intervals {
                        let dayStart = calendar.startOfDay(for: interval.timestamp)
                        dayIntervals[dayStart, default: []].append(interval)
                    }
                    if !results.intervals.isEmpty {
                        for interval in results.intervals where interval.steps > 0 {
                            let ts = interval.timestamp
                            var stepSampleCheck = FetchDescriptor<CompassData.StepSample>(
                                predicate: #Predicate<CompassData.StepSample> { s in
                                    s.timestamp == ts
                                }
                            )
                            stepSampleCheck.fetchLimit = 1
                            let existing = (try? context.fetch(stepSampleCheck)) ?? []
                            if existing.isEmpty {
                                context.insert(CompassData.StepSample(
                                    timestamp: ts,
                                    steps: interval.steps
                                ))
                            }
                        }
                        for interval in results.intervals where interval.intensityMinutes > 0 {
                            let ts = interval.timestamp
                            var intensityCheck = FetchDescriptor<CompassData.IntensitySample>(
                                predicate: #Predicate<CompassData.IntensitySample> { s in
                                    s.timestamp == ts
                                }
                            )
                            intensityCheck.fetchLimit = 1
                            if (try? context.fetch(intensityCheck))?.first == nil {
                                context.insert(CompassData.IntensitySample(
                                    timestamp: ts,
                                    minutes: interval.intensityMinutes
                                ))
                            }
                        }
                    }
                    var insertedDays = 0
                    for (day, dayData) in dayIntervals {
                        let dayIntensityMinutes = dayData.reduce(0) { $0 + $1.intensityMinutes }
                        let dayCalories = dayData.reduce(0.0) { $0 + $1.activeCalories }

                        // Aggregate steps from persisted StepSample rows so partial re-syncs
                        // never overwrite a larger accumulated total.
                        let dayStart = day
                        let dayEnd = calendar.date(byAdding: .day, value: 1, to: day)!
                        let stepDescriptor = FetchDescriptor<CompassData.StepSample>(
                            predicate: #Predicate<CompassData.StepSample> { s in
                                s.timestamp >= dayStart && s.timestamp < dayEnd
                            }
                        )
                        let totalSteps = ((try? context.fetch(stepDescriptor)) ?? []).reduce(0) { $0 + $1.steps }

                        let dayDate = day
                        var stepCheck = FetchDescriptor<CompassData.StepCount>(
                            predicate: #Predicate<CompassData.StepCount> { count in
                                count.date == dayDate
                            }
                        )
                        stepCheck.fetchLimit = 1
                        let existingCounts = (try? context.fetch(stepCheck)) ?? []
                        if let existing = existingCounts.first {
                            existing.steps = totalSteps
                            existing.intensityMinutes = max(existing.intensityMinutes, dayIntensityMinutes)
                            existing.calories = max(existing.calories, dayCalories)
                        } else {
                            context.insert(CompassData.StepCount(date: day, steps: totalSteps, intensityMinutes: dayIntensityMinutes, calories: dayCalories))
                            insertedDays += 1
                        }
                    }
                    AppLogger.sync.debug("Inserted monitoring data: \(results.heartRateSamples.count) HR, \(results.stressSamples.count) stress, \(results.bodyBatterySamples.count) BB, \(results.respirationSamples.count) resp, \(results.spo2Samples.count) SpO2, \(results.intervals.count) intervals → \(insertedDays) day(s)")
                } catch {
                    AppLogger.sync.error("Monitoring parse failed for \(filename): \(error.localizedDescription)")
                }
            } else if filename.contains("sleep") || filename.contains("slp") {
                let parser = SleepFITParser(profile: deviceProfile)
                do {
                    if let result = try await parser.parse(data: fileData) {
                        parsedOK = true
                        let lowerBound = result.startDate.addingTimeInterval(-3600)
                        let upperBound = result.startDate.addingTimeInterval(3600)
                        var sleepCheck = FetchDescriptor<SleepSession>(
                            predicate: #Predicate<SleepSession> { s in
                                s.startDate >= lowerBound && s.startDate <= upperBound
                            }
                        )
                        sleepCheck.fetchLimit = 1
                        let existingSessions = (try? context.fetch(sleepCheck)) ?? []
                        if existingSessions.isEmpty {
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
                        } else if let existing = existingSessions.first,
                                  existing.score == nil, result.score != nil {
                            // Assessment-only file arriving after per-stage file: fill in missing scores.
                            existing.score = result.score
                            existing.recoveryScore = result.recoveryScore
                            existing.qualifier = result.qualifier
                            AppLogger.sync.debug("Merged assessment scores into existing sleep session near \(result.startDate)")
                        } else {
                            AppLogger.sync.debug("Skipping duplicate sleep session near \(result.startDate)")
                        }
                    } else {
                        AppLogger.sync.info("Sleep file produced no usable result: \(filename)")
                    }
                } catch {
                    AppLogger.sync.error("Sleep parse failed for \(filename): \(error.localizedDescription)")
                }
            } else if filename.contains("metric") || filename.contains("met") {
                let parser = MetricsFITParser()
                do {
                    let results = try await parser.parse(data: fileData)
                    parsedOK = true
                    for sample in results {
                        context.insert(HRVSample(timestamp: sample.timestamp, rmssd: sample.rmssd, context: .resting))
                    }
                    AppLogger.sync.debug("Inserted \(results.count) HRV samples")
                } catch {
                    AppLogger.sync.error("Metrics parse failed for \(filename): \(error.localizedDescription)")
                }
            } else {
                AppLogger.sync.warning("Unrecognized FIT filename pattern: \(filename)")
            }

            if parsedOK {
                await deviceManager.archiveFITFile(fileIndex: fileIndex)
            }
        }

        try? context.save()
        AppLogger.sync.info("SwiftData save complete")
        lastSyncDate = Date()
        return savedEntries.count
    }

    private func processWatchInitiatedURLs(_ entries: [(url: URL, fileIndex: UInt16)]) async {
        beginBackgroundTask()
        defer { endBackgroundTask() }
        let context = ModelContext(modelContainer)
        await processFITFiles(entries, context: context)
    }

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
}
