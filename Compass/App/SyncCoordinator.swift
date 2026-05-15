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
    var transferBytes: (received: Int, total: Int?)? = nil

    // MARK: - Watch Activity (lightweight, non-sync interactions)

    /// The most recent short-lived watch interaction (weather request, FMP,
    /// archive, etc.). The UI animates a pulse on the connection dot whenever
    /// this changes — the count is what triggers the animation, the kind drives
    /// the optional label.
    var lastWatchActivity: WatchActivityEvent?

    /// Monotonic counter incremented on every watch-activity event. Views use
    /// this as the `trigger` for a `.task(id:)` modifier so each event produces
    /// exactly one pulse animation, even when several events fire in a row.
    var watchActivityPulseCount: Int = 0

    let deviceManager: any DeviceManagerProtocol
    private let modelContainer: ModelContainer

    /// The last device we successfully connected to, kept for auto-reconnect.
    private var lastConnectedDevice: PairedDevice?

    /// Name of the most recent paired device, kept for status UI while
    /// disconnected/connecting (when `connectionState` carries no name).
    var lastKnownDeviceName: String? { lastConnectedDevice?.name }

    /// Device profile derived from the paired device's product ID.
    private var deviceProfile: DeviceProfile = .default

    private var discoveryTask: Task<Void, Never>?
    private var connectionMonitorTask: Task<Void, Never>?
    private var watchSyncProgressTask: Task<Void, Never>?
    private var watchActivityTask: Task<Void, Never>?
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

        watchSyncProgressTask = Task { [self] in
            for await event in deviceManager.watchSyncProgressStream() {
                applyWatchSyncProgress(event)
            }
        }

        watchActivityTask = Task { [self] in
            for await event in deviceManager.watchActivityStream() {
                lastWatchActivity = event
                watchActivityPulseCount &+= 1
            }
        }
    }

    /// Updates `state` / `progress` for syncs that the watch initiated (5037
    /// SYNCHRONIZATION). Mirrors the switch in `sync(context:)`. Phone-initiated
    /// syncs use a local stream inside that method, so this only runs for
    /// background syncs — keeping the status pill honest when files arrive
    /// without the user tapping anything.
    private func applyWatchSyncProgress(_ event: SyncProgress) {
        AppLogger.sync.debug("Watch-initiated progress: \(event.description)")
        switch event {
        case .starting:
            state = .syncing(description: "Connecting...")
        case .listing(let dir):
            state = .syncing(description: "Listing \(dir.rawValue) files...")
        case .downloading(let file, let received, let total):
            let totalStr = total.map { " / \($0)" } ?? ""
            state = .syncing(description: "Downloading \(file): \(received)\(totalStr) bytes")
            if let total, total > 0 {
                progress = Double(received) / Double(total)
            }
            transferBytes = (received, total)
        case .parsing:
            state = .syncing(description: "Parsing data...")
            transferBytes = nil
        case .completed(let count):
            state = .completed(fileCount: count)
            transferBytes = nil
            progress = 0
            lastSyncDate = Date()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                await MainActor.run {
                    guard let self else { return }
                    if case .completed = self.state { self.state = .idle }
                }
            }
        case .failed(let error):
            state = .failed(error.localizedDescription)
            transferBytes = nil
            progress = 0
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                await MainActor.run {
                    guard let self else { return }
                    if case .failed = self.state { self.state = .idle }
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
        transferBytes = nil
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

        musicService.startObserving { [weak gm, weak self] messages in
            Task { [weak gm, weak self] in
                await gm?.sendMusicEntityUpdate(messages)
                await self?.recordWatchActivity(.music)
            }
        }
        musicService.pushCurrentState()

        phoneLocationService.sendMessage = { [weak gm, weak self] msg in
            try? await gm?.sendRaw(message: msg)
            await self?.recordWatchActivity(.location)
        }
        weatherService.locationProvider = { [weak phoneLocationService] in
            phoneLocationService?.latestLocation
        }
        phoneLocationService.startUpdating()

        await gm.setWatchInitiatedSyncHandler { [weak self] entries in
            guard let self else { return }
            await self.processWatchInitiatedURLs(entries)
        }

        AppLogger.sync.info("Watch services wired: weather, find-my-phone, music, phone-location")
    }

    /// Bumps the watch-activity pulse for outbound interactions that we trigger
    /// (music push, location push, course upload). Inbound interactions
    /// (weather request, FMP, archive ACK) come through `watchActivityStream`
    /// inside the device manager — no need to call this for those.
    private func recordWatchActivity(_ kind: WatchActivityKind) {
        lastWatchActivity = WatchActivityEvent(kind: kind)
        watchActivityPulseCount &+= 1
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
                            self.transferBytes = (received, total)
                        case .parsing:
                            self.state = .syncing(description: "Parsing data...")
                            self.transferBytes = nil
                        case .completed(let count):
                            self.state = .completed(fileCount: count)
                            self.transferBytes = nil
                        case .failed(let error):
                            self.state = .failed(error.localizedDescription)
                            self.transferBytes = nil
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
            if let saved = try? FITFileStore.shared.save(from: entry.url, fileIndex: entry.fileIndex) {
                savedEntries.append((url: saved, fileIndex: entry.fileIndex))
                AppLogger.sync.debug("Saved FIT file: \(saved.lastPathComponent)")
            } else {
                AppLogger.sync.warning("Failed to save FIT file: \(entry.url.lastPathComponent)")
            }
        }

        await parseAndFinalize(savedEntries, archiveOnSuccess: true, context: context)
        lastSyncDate = Date()
        return savedEntries.count
    }

    /// Shared post-pass for every flow that turns FIT files into SwiftData rows:
    /// parse each entry, run sleep-session cleanup over the full merged set, then
    /// save. Centralising this means `sync` / `importFITFiles` / `reparseLocalFITFiles`
    /// can never silently diverge on the post-parse steps (e.g. forgetting to call
    /// `cleanupSleepSessions`, which re-validates merged sleep across midnight-split
    /// halves and trims edge awake).
    private func parseAndFinalize(
        _ entries: [(url: URL, fileIndex: UInt16)],
        archiveOnSuccess: Bool,
        context: ModelContext
    ) async {
        for entry in entries {
            await parseAndPersistFITFile(url: entry.url, fileIndex: entry.fileIndex,
                                         archiveOnSuccess: archiveOnSuccess, context: context)
        }
        cleanupSleepSessions(context: context)
        try? context.save()
    }

    /// Imports FIT files from external URLs (e.g. an archive of files previously
    /// exported via the share sheet). Each file is copied into the local FIT cache
    /// and parsed into SwiftData. Existing rows are preserved via the same
    /// dedup checks used during sync.
    @discardableResult
    func importFITFiles(urls: [URL]) async -> Int {
        // Same rationale as `processWatchInitiatedURLs` — write through the
        // SwiftUI environment context so @Query observers refresh.
        let context = modelContainer.mainContext
        AppLogger.sync.info("Importing \(urls.count) external FIT file(s)")

        var savedEntries: [(url: URL, fileIndex: UInt16)] = []
        for url in urls {
            let securityScoped = url.startAccessingSecurityScopedResource()
            defer { if securityScoped { url.stopAccessingSecurityScopedResource() } }

            guard let saved = try? FITFileStore.shared.save(from: url) else {
                AppLogger.sync.warning("Failed to copy imported FIT file: \(url.lastPathComponent)")
                continue
            }
            AppLogger.sync.debug("Copied imported file to: \(saved.lastPathComponent)")
            savedEntries.append((url: saved, fileIndex: 0))
        }

        await parseAndFinalize(savedEntries, archiveOnSuccess: false, context: context)
        AppLogger.sync.info("Import complete (\(savedEntries.count)/\(urls.count) file(s))")
        return savedEntries.count
    }

    /// Wipes every FIT-derived row from the local database and re-imports from the
    /// FIT file cache. ConnectedDevice and Course* rows are preserved (they don't
    /// come from FIT files). Used as a developer reset after parser changes.
    @discardableResult
    func reparseLocalFITFiles() async -> Int {
        // Same rationale as `processWatchInitiatedURLs` — write through the
        // SwiftUI environment context so @Query observers refresh.
        let context = modelContainer.mainContext

        AppLogger.sync.info("Wiping FIT-derived data before reparse")
        try? context.delete(model: Activity.self)
        try? context.delete(model: TrackPoint.self)
        try? context.delete(model: SleepSession.self)
        try? context.delete(model: SleepStage.self)
        try? context.delete(model: HeartRateSample.self)
        try? context.delete(model: HRVSample.self)
        try? context.delete(model: StressSample.self)
        try? context.delete(model: CompassData.BodyBatterySample.self)
        try? context.delete(model: CompassData.RespirationSample.self)
        try? context.delete(model: SpO2Sample.self)
        try? context.delete(model: CompassData.IntensitySample.self)
        try? context.delete(model: CompassData.StepCount.self)
        try? context.delete(model: CompassData.StepSample.self)
        try? context.save()

        let files = FITFileStore.shared.allFiles()
        AppLogger.sync.info("Reparsing \(files.count) local FIT file(s)")

        // Pull a numeric suffix off each stored filename for logging only —
        // `archiveOnSuccess` is false here so we never re-archive on the watch.
        let entries: [(url: URL, fileIndex: UInt16)] = files.map { file in
            let suffix = file.name
                .replacingOccurrences(of: ".fit", with: "")
                .split(separator: "_").last
            let fileIndex = suffix.flatMap { UInt16($0) } ?? 0
            return (url: file.url, fileIndex: fileIndex)
        }

        await parseAndFinalize(entries, archiveOnSuccess: false, context: context)
        AppLogger.sync.info("Reparse complete (\(files.count) file(s))")
        return files.count
    }

    private func parseAndPersistFITFile(
        url: URL,
        fileIndex: UInt16,
        archiveOnSuccess: Bool,
        context: ModelContext
    ) async {
        guard let fileData = try? Data(contentsOf: url) else {
            AppLogger.sync.warning("Could not read FIT file at: \(url.lastPathComponent)")
            return
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
                    if !results.restingHeartRateSamples.isEmpty {
                        let firstTS = results.restingHeartRateSamples.first!.timestamp
                        let lastTS  = results.restingHeartRateSamples.last!.timestamp
                        let restingContext = HeartRateContext.resting
                        let existingRestingTimes: Set<Date> = {
                            let d = FetchDescriptor<HeartRateSample>(
                                predicate: #Predicate<HeartRateSample> { hr in
                                    hr.timestamp >= firstTS && hr.timestamp <= lastTS
                                        && hr.context == restingContext
                                }
                            )
                            return Set(((try? context.fetch(d)) ?? []).map(\.timestamp))
                        }()
                        for sample in results.restingHeartRateSamples where !existingRestingTimes.contains(sample.timestamp) {
                            context.insert(HeartRateSample(timestamp: sample.timestamp, bpm: sample.bpm, context: .resting))
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

                    // Per-interval step deltas: the parser skips the first cumulative
                    // reading per file (a snapshot, not a true delta), so summing these
                    // gives an accurate per-hour distribution but may miss the file's
                    // pre-window steps. The daily total comes from `dailyStepTotals`.
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

                    // Active / intensity minutes: one IntensitySample per minute that
                    // contained any HR sample at or above the threshold.
                    for ts in results.activeMinuteTimestamps {
                        var intensityCheck = FetchDescriptor<CompassData.IntensitySample>(
                            predicate: #Predicate<CompassData.IntensitySample> { s in
                                s.timestamp == ts
                            }
                        )
                        intensityCheck.fetchLimit = 1
                        if (try? context.fetch(intensityCheck))?.first == nil {
                            context.insert(CompassData.IntensitySample(timestamp: ts, minutes: 1))
                        }
                    }

                    // Daily aggregates. Steps total comes from the parser's day-cumulative
                    // max (authoritative even when the file starts mid-day); intensity
                    // minutes are counted from `activeMinuteTimestamps` per day; calories
                    // are summed from the intervals.
                    // `dayBucket` matches the parser's bucketing so end-of-day summary
                    // records (timestamped exactly at local midnight) attribute to the
                    // day they describe rather than the next one. Intensity minutes
                    // come from HR samples, which never land at exact midnight, so
                    // either bucketing function would work — using `dayBucket` for
                    // consistency.
                    var dayCalories: [Date: Double] = [:]
                    for interval in results.intervals {
                        let day = MonitoringFITParser.dayBucket(for: interval.timestamp)
                        dayCalories[day, default: 0] += interval.activeCalories
                    }
                    var dayIntensityMin: [Date: Int] = [:]
                    for ts in results.activeMinuteTimestamps {
                        let day = MonitoringFITParser.dayBucket(for: ts)
                        dayIntensityMin[day, default: 0] += 1
                    }

                    let allDays = Set(results.dailyStepTotals.keys)
                        .union(dayCalories.keys)
                        .union(dayIntensityMin.keys)

                    var insertedDays = 0
                    for day in allDays {
                        let totalSteps = results.dailyStepTotals[day] ?? 0
                        let intensityMin = dayIntensityMin[day] ?? 0
                        let calories = dayCalories[day] ?? 0

                        let dayDate = day
                        var stepCheck = FetchDescriptor<CompassData.StepCount>(
                            predicate: #Predicate<CompassData.StepCount> { count in
                                count.date == dayDate
                            }
                        )
                        stepCheck.fetchLimit = 1
                        let existingCounts = (try? context.fetch(stepCheck)) ?? []
                        if let existing = existingCounts.first {
                            // Use max so partial re-syncs never shrink an authoritative total.
                            existing.steps = max(existing.steps, totalSteps)
                            existing.intensityMinutes = max(existing.intensityMinutes, intensityMin)
                            existing.calories = max(existing.calories, calories)
                        } else {
                            context.insert(CompassData.StepCount(
                                date: day,
                                steps: totalSteps,
                                intensityMinutes: intensityMin,
                                calories: calories
                            ))
                            insertedDays += 1
                        }
                    }
                    AppLogger.sync.debug("Inserted monitoring data: \(results.heartRateSamples.count) HR, \(results.restingHeartRateSamples.count) resting HR, \(results.stressSamples.count) stress, \(results.bodyBatterySamples.count) BB, \(results.respirationSamples.count) resp, \(results.spo2Samples.count) SpO2, \(results.intervals.count) intervals, \(results.activeMinuteTimestamps.count) active min → \(insertedDays) day(s)")
                } catch {
                    AppLogger.sync.error("Monitoring parse failed for \(filename): \(error.localizedDescription)")
                }
            } else if filename.contains("sleep") || filename.contains("slp") {
                let parser = SleepFITParser(profile: deviceProfile)
                do {
                    if let result = try await parser.parse(data: fileData) {
                        parsedOK = true
                        mergeOrInsertSleepResult(result, context: context)
                    } else {
                        // File parsed cleanly but produced no usable session (tiny header-only files
                        // are common — the watch emits empty sleep stubs around connection events).
                        // Treat as success so it gets archived; otherwise we re-pull it forever.
                        parsedOK = true
                        AppLogger.sync.debug("Sleep file produced no usable result: \(filename) — archiving anyway")
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

        if parsedOK && archiveOnSuccess {
            await deviceManager.archiveFITFile(fileIndex: fileIndex)
        }
    }

    private func processWatchInitiatedURLs(_ entries: [(url: URL, fileIndex: UInt16)]) async {
        beginBackgroundTask()
        defer { endBackgroundTask() }
        // Use the container's main-actor context (the same one SwiftUI's
        // `@Environment(\.modelContext)` exposes, which every view-tree `@Query`
        // observes) rather than a detached `ModelContext(modelContainer)`. With
        // a detached context, saves write to the store but the UI's @Query
        // doesn't pick them up until something else triggers a re-fetch — so
        // watch-initiated syncs would land in the database but stay invisible
        // until the user hit manual Sync, which writes through the UI context
        // directly. SyncCoordinator is `@MainActor`-isolated, so accessing
        // `mainContext` is straight-line. See `docs/issues/background_sync_ui_refresh.md`.
        await processFITFiles(entries, context: modelContainer.mainContext)
    }

    func uploadCourse(fitURL: URL, fitSize: Int, course: Course) {
        guard case .idle = state else {
            AppLogger.sync.warning("Upload requested but already in state: \(String(describing: self.state))")
            return
        }

        AppLogger.sync.info("Starting course upload")
        state = .syncing(description: "Uploading course...")
        progress = 0

        do {
            let staged = try CourseFileStore.shared.save(from: fitURL)
            AppLogger.sync.info("Staged course FIT for inspection: \(staged.lastPathComponent)")
        } catch {
            AppLogger.sync.warning("Failed to stage course FIT: \(error.localizedDescription)")
        }

        syncTask = Task {
            let (stream, continuation) = AsyncStream<SyncProgress>.makeStream()
            let progressTask = Task {
                for await event in stream {
                    await MainActor.run {
                        switch event {
                        case .downloading(_, let sent, let total):
                            let totalStr = total.map { " / \($0)" } ?? ""
                            self.state = .syncing(description: "Uploading course: \(sent)\(totalStr) bytes")
                            if let total, total > 0 {
                                self.progress = Double(sent) / Double(total)
                            }
                            self.transferBytes = (sent, total)
                        default:
                            break
                        }
                    }
                }
            }
            defer {
                continuation.finish()
                progressTask.cancel()
            }
            do {
                let fileIndex = try await deviceManager.uploadCourse(fitURL, progress: continuation)
                AppLogger.sync.info("Course uploaded successfully (fileIndex=\(fileIndex), size=\(fitSize)B)")
                course.uploadedToWatch = true
                course.lastUploadDate = Date()
                course.watchFITSize = fitSize
                state = .completed(fileCount: 1)
                transferBytes = nil
                progress = 0

                try? await Task.sleep(for: .seconds(3))
                state = .idle

            } catch {
                AppLogger.sync.error("Upload failed: \(error.localizedDescription)")
                state = .failed(error.localizedDescription)
                transferBytes = nil
                progress = 0
                try? await Task.sleep(for: .seconds(5))
                state = .idle
            }
        }
    }

    // MARK: - Sleep session merge

    /// Time gap (in either direction) within which a new sleep file is considered to
    /// belong to the same `SleepSession`. The watch emits one FIT file per uninterrupted
    /// sleep block, so a single night typically arrives as 4-6 segments.
    private static let sleepMergeWindow: TimeInterval = 30 * 60

    /// Tolerance used to detect a sleep-file boundary that lands on local midnight —
    /// the watch firmware closes one sleep file and opens the next at exactly that
    /// instant, so msg 273/276 timestamps within this window of midnight are treated
    /// as "this is the firmware's daily split, not a real session boundary."
    private static let midnightTolerance: TimeInterval = 5 * 60

    private static func isNearLocalMidnight(_ date: Date) -> Bool {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: date)
        guard let nextDay = cal.date(byAdding: .day, value: 1, to: startOfDay) else { return false }
        let toStart = abs(date.timeIntervalSince(startOfDay))
        let toNext = abs(date.timeIntervalSince(nextDay))
        return min(toStart, toNext) <= midnightTolerance
    }

    /// Merges a parsed `SleepResult` into any adjacent `SleepSession`, or inserts a new one.
    /// Recomputes the session's `startDate`/`endDate` from the merged stages using
    /// `SleepStageResult.trimmedBounds`. Files whose stages don't yield a qualifying
    /// sleep block (no light/deep, or too short) are dropped — these are watch
    /// false-positives during low-motion daytime periods.
    private func mergeOrInsertSleepResult(_ result: SleepResult, context: ModelContext) {
        let queryLow = result.startDate.addingTimeInterval(-Self.sleepMergeWindow)
        let queryHigh = result.endDate.addingTimeInterval(Self.sleepMergeWindow)
        let descriptor = FetchDescriptor<SleepSession>(
            predicate: #Predicate<SleepSession> { s in
                s.endDate >= queryLow && s.startDate <= queryHigh
            },
            sortBy: [SortDescriptor(\.startDate)]
        )
        let candidates = (try? context.fetch(descriptor)) ?? []

        // Assessment-only file (no stages, just a score): merge into nearest candidate or insert as standalone.
        if result.stages.isEmpty {
            if let target = candidates.min(by: {
                abs($0.startDate.timeIntervalSince(result.startDate)) <
                abs($1.startDate.timeIntervalSince(result.startDate))
            }) {
                if target.score == nil    { target.score = result.score }
                if target.recoveryScore == nil { target.recoveryScore = result.recoveryScore }
                if target.qualifier == nil { target.qualifier = result.qualifier }
                AppLogger.sync.debug("Merged assessment scores into sleep session near \(result.startDate)")
            } else {
                let session = SleepSession(
                    startDate: result.startDate,
                    endDate: result.endDate,
                    score: result.score,
                    recoveryScore: result.recoveryScore,
                    qualifier: result.qualifier
                )
                context.insert(session)
                AppLogger.sync.debug("Inserted assessment-only sleep session at \(result.startDate)")
            }
            return
        }

        if let primary = candidates.first {
            // Append new stages, dropping any that already exist at the same start.
            var existingStarts = Set(primary.stages.map(\.startDate))
            for stageResult in result.stages where !existingStarts.contains(stageResult.startDate) {
                let stage = SleepStage(
                    startDate: stageResult.startDate,
                    endDate: stageResult.endDate,
                    stage: stageResult.stage,
                    session: primary
                )
                context.insert(stage)
                existingStarts.insert(stageResult.startDate)
            }

            // Reparent stages from any other candidate sessions in the window, then delete those sessions.
            for other in candidates.dropFirst() {
                for stage in other.stages where !existingStarts.contains(stage.startDate) {
                    stage.session = primary
                    existingStarts.insert(stage.startDate)
                }
                context.delete(other)
            }

            // Carry over scoring fields.
            if primary.score == nil         { primary.score = result.score }
            if primary.recoveryScore == nil { primary.recoveryScore = result.recoveryScore }
            if primary.qualifier == nil     { primary.qualifier = result.qualifier }

            // Recompute trimmed bounds from the merged stage set.
            let merged = primary.stages
                .map { SleepStageResult(startDate: $0.startDate, endDate: $0.endDate, stage: $0.stage) }
                .sorted { $0.startDate < $1.startDate }
            if let bounds = SleepStageResult.trimmedBounds(stages: merged) {
                primary.startDate = bounds.start
                primary.endDate = bounds.end
                AppLogger.sync.debug("Merged sleep session: \(primary.startDate) – \(primary.endDate) (\(primary.stages.count) stage(s))")
            } else {
                // Merged stages don't form a qualifying sleep block — drop the session.
                // (Cascade-deletes the stages.)
                context.delete(primary)
                AppLogger.sync.debug("Dropped merged sleep session — no qualifying sleep block")
            }
            return
        }

        // No adjacent session — pick session bounds from strongest to weakest source:
        //   1. `trimmedBounds`   — quality-validated sleep block (preferred).
        //   2. First→last non-awake stage — used only when the file touches local
        //      midnight, so the firmware's nightly midnight-split halves still get
        //      persisted long enough for a sibling file to find them via the merge
        //      query. Skipping the quality gate here means we may briefly hold a
        //      noisy half-session, but `cleanupSleepSessions` re-runs `trimmedBounds`
        //      at end of sync and deletes any that don't qualify after merging.
        //   3. Drop the file otherwise.
        // We never use raw msg 273/276 bounds verbatim — those include the file's
        // leading/trailing awake padding and would land "too-long" sessions on disk.
        let sortedStages = result.stages.sorted { $0.startDate < $1.startDate }
        let qualifying = SleepStageResult.trimmedBounds(stages: sortedStages)
        let touchesMidnight = Self.isNearLocalMidnight(result.startDate)
                           || Self.isNearLocalMidnight(result.endDate)

        let bounds: (start: Date, end: Date)?
        if let q = qualifying {
            bounds = q
        } else if touchesMidnight {
            let nonAwake = sortedStages.filter { $0.stage != .awake }
            if let first = nonAwake.first, let last = nonAwake.last {
                bounds = (first.startDate, last.endDate)
            } else {
                bounds = nil
            }
        } else {
            bounds = nil
        }

        guard let bounds else {
            AppLogger.sync.debug("Sleep file dropped — no qualifying sleep block (likely watch false-positive)")
            return
        }
        let session = SleepSession(
            startDate: bounds.start,
            endDate: bounds.end,
            score: result.score,
            recoveryScore: result.recoveryScore,
            qualifier: result.qualifier
        )
        context.insert(session)
        for stageResult in sortedStages {
            let stage = SleepStage(
                startDate: stageResult.startDate,
                endDate: stageResult.endDate,
                stage: stageResult.stage,
                session: session
            )
            context.insert(stage)
        }
        AppLogger.sync.debug("Inserted sleep session: \(session.startDate) – \(session.endDate) with \(sortedStages.count) stage(s)")
    }

    /// Re-validates every persisted `SleepSession` against the current `trimmedBounds`
    /// heuristic. Sessions whose stages don't yield a qualifying sleep block are
    /// deleted; the rest have their bounds refreshed. Run at end of sync to evict
    /// noise sessions persisted by older heuristics.
    private func cleanupSleepSessions(context: ModelContext) {
        let descriptor = FetchDescriptor<SleepSession>()
        guard let sessions = try? context.fetch(descriptor) else { return }

        var deleted = 0
        var refreshed = 0
        for session in sessions {
            let stages = session.stages
                .map { SleepStageResult(startDate: $0.startDate, endDate: $0.endDate, stage: $0.stage) }
                .sorted { $0.startDate < $1.startDate }

            // Assessment-only sessions (no stages, just a score) are kept as-is.
            if stages.isEmpty { continue }

            if let bounds = SleepStageResult.trimmedBounds(stages: stages) {
                if session.startDate != bounds.start || session.endDate != bounds.end {
                    session.startDate = bounds.start
                    session.endDate = bounds.end
                    refreshed += 1
                }
            } else {
                context.delete(session)
                deleted += 1
            }
        }
        if deleted + refreshed > 0 {
            AppLogger.sync.info("Sleep cleanup: deleted \(deleted) noise session(s), refreshed bounds on \(refreshed)")
        }
    }

    // MARK: - Data hygiene

    func archiveFITFile(named filename: String) async {
        guard let idStr = filename
                .replacingOccurrences(of: ".fit", with: "")
                .split(separator: "_").last,
              let fileIndex = UInt16(idStr)
        else {
            AppLogger.sync.warning("Cannot derive fileIndex from \(filename)")
            return
        }
        await deviceManager.archiveFITFile(fileIndex: fileIndex)
        AppLogger.sync.info("Manually archived fileIndex=\(fileIndex)")
    }

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
