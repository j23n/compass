import Foundation
import SwiftData
import CompassData
import CompassHealth

/// @MainActor @Observable glue between Settings, the BLE sync pipeline, and
/// the HealthKit exporter. Owns the user-facing "Sync to Apple Health"
/// toggle and the export cursor / schema-version that survive app launches.
@Observable
@MainActor
final class HealthKitSyncService {

    // MARK: - Persistent state (UserDefaults-backed)

    private enum Keys {
        static let enabled = "health.syncEnabled"
        static let lastSuccessfulExport = "health.lastSuccessfulExport"
        static let exportSchemaVersion = "health.exportSchemaVersion"
        static let lastError = "health.lastError"
        static let lastSummary = "health.lastSummary"
    }

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.enabled) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.enabled) }
    }

    var lastSuccessfulExport: Date? {
        get {
            let ts = UserDefaults.standard.double(forKey: Keys.lastSuccessfulExport)
            return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
        }
        set {
            if let date = newValue {
                UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Keys.lastSuccessfulExport)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.lastSuccessfulExport)
            }
        }
    }

    private var storedSchemaVersion: Int {
        get { UserDefaults.standard.integer(forKey: Keys.exportSchemaVersion) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.exportSchemaVersion) }
    }

    var lastError: String? {
        get { UserDefaults.standard.string(forKey: Keys.lastError) }
        set {
            if let v = newValue {
                UserDefaults.standard.set(v, forKey: Keys.lastError)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.lastError)
            }
        }
    }

    var lastSummary: ExportSummary? {
        get {
            guard let data = UserDefaults.standard.data(forKey: Keys.lastSummary) else { return nil }
            return try? JSONDecoder().decode(ExportSummary.self, from: data)
        }
        set {
            if let v = newValue, let data = try? JSONEncoder().encode(v) {
                UserDefaults.standard.set(data, forKey: Keys.lastSummary)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.lastSummary)
            }
        }
    }

    // MARK: - Live status

    enum Phase: Sendable, Equatable {
        case idle
        case running(done: Int, total: Int, label: String)
        case succeeded
        case failed(String)
        case cancelled
    }

    private(set) var phase: Phase = .idle

    private let exporter: any HealthKitExporterProtocol
    private let modelContainer: ModelContainer
    private var activeTask: Task<Void, Never>?

    init(exporter: any HealthKitExporterProtocol, modelContainer: ModelContainer) {
        self.exporter = exporter
        self.modelContainer = modelContainer
    }

    var isAvailable: Bool { exporter.isAvailable() }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    /// Snapshot version of `phase` for views that want a fixed value rather
    /// than to track `@Observable` updates.
    var phaseDescription: String {
        switch phase {
        case .idle: "Idle"
        case .running(let done, let total, let label):
            total > 0 ? "\(label): \(done) / \(total)" : "\(label)…"
        case .succeeded: "Last export succeeded"
        case .failed(let msg): "Last export failed: \(msg)"
        case .cancelled: "Cancelled"
        }
    }

    // MARK: - User-facing entry points

    /// Called from the Settings toggle. Requests authorization and, on
    /// success, starts the initial full backfill.
    func enable() {
        AppLogger.health.info("User enabling Apple Health sync")
        Task {
            do {
                let result = try await exporter.requestAuthorization()
                switch result {
                case .authorized:
                    isEnabled = true
                    runFullReconcile()
                case .denied:
                    lastError = "Apple Health permission was denied."
                    isEnabled = false
                    AppLogger.health.warning("Authorization denied")
                case .unavailable:
                    lastError = "Apple Health is not available on this device."
                    isEnabled = false
                    AppLogger.health.warning("HealthKit unavailable")
                }
            } catch {
                lastError = error.localizedDescription
                isEnabled = false
                AppLogger.health.error("Authorization request threw: \(error.localizedDescription)")
            }
        }
    }

    func disable() {
        AppLogger.health.info("User disabling Apple Health sync")
        cancel()
        isEnabled = false
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        if isRunning { phase = .cancelled }
    }

    /// Manual button in Settings: wipe everything Compass has written and
    /// re-export from scratch.
    func runFullReconcile() {
        guard isEnabled, isAvailable else { return }
        guard !isRunning else { return }

        activeTask = Task { [weak self] in
            guard let self else { return }
            await self.performFullReconcile()
        }
    }

    /// Called from `SyncCoordinator.parseAndFinalize` after every BLE sync.
    /// On schema-version mismatch this falls through to a full reconcile;
    /// otherwise it's an incremental export of rows newer than the cursor.
    func runIncrementalExport() {
        guard isEnabled, isAvailable else { return }
        guard !isRunning else { return }

        if storedSchemaVersion != CompassExportSchemaVersion.current {
            AppLogger.health.info("Schema version mismatch (\(self.storedSchemaVersion) → \(CompassExportSchemaVersion.current)); running full reconcile")
            runFullReconcile()
            return
        }

        activeTask = Task { [weak self] in
            guard let self else { return }
            await self.performIncrementalExport()
        }
    }

    // MARK: - Implementation

    private func performIncrementalExport() async {
        phase = .running(done: 0, total: 0, label: "Exporting to Apple Health")
        let cursor = lastSuccessfulExport
        let context = ModelContext(modelContainer)
        let snapshot = HealthSnapshotBuilder.build(context: context, since: cursor)

        await runExport(snapshot: snapshot, cursorAfter: Date())
    }

    private func performFullReconcile() async {
        phase = .running(done: 0, total: 0, label: "Refreshing Apple Health")
        AppLogger.health.info("Full reconcile: wiping Compass-sourced HK data")

        do {
            let deletion = try await exporter.deleteAllCompassData()
            AppLogger.health.info("Wipe removed \(deletion.total) HK objects across \(deletion.perType.count) types")
        } catch {
            AppLogger.health.error("Wipe failed: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
            lastError = error.localizedDescription
            return
        }

        let context = ModelContext(modelContainer)
        let snapshot = HealthSnapshotBuilder.build(context: context, since: nil)
        await runExport(snapshot: snapshot, cursorAfter: Date(), bumpSchemaVersion: true)
    }

    private func runExport(
        snapshot: HealthDataSnapshot,
        cursorAfter: Date,
        bumpSchemaVersion: Bool = false
    ) async {
        guard !snapshot.isEmpty else {
            phase = .succeeded
            lastSuccessfulExport = cursorAfter
            if bumpSchemaVersion {
                storedSchemaVersion = CompassExportSchemaVersion.current
            }
            AppLogger.health.info("Export: nothing to do")
            return
        }

        let total = snapshot.totalCount
        phase = .running(done: 0, total: total, label: "Exporting to Apple Health")
        AppLogger.health.info("Exporting \(total) HK objects (cursor: \(self.lastSuccessfulExport?.description ?? "none"))")

        let progress: @Sendable (ExportProgress) -> Void = { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .running = self.phase {
                    let label = "Exporting \(self.phaseLabel(for: event.phase))"
                    self.phase = .running(done: event.done, total: event.total, label: label)
                }
            }
        }

        do {
            let summary = try await exporter.export(snapshot: snapshot, progress: progress)
            lastSummary = summary
            lastSuccessfulExport = cursorAfter
            lastError = nil
            if bumpSchemaVersion {
                storedSchemaVersion = CompassExportSchemaVersion.current
            }
            phase = .succeeded
            AppLogger.health.info("Export done: workouts=\(summary.workoutsAdded), routes=\(summary.routesAdded), sleepStages=\(summary.sleepStagesAdded), samples=\(summary.quantitySamplesAdded), failures=\(summary.perTypeFailures.values.reduce(0, +))")
        } catch is CancellationError {
            phase = .cancelled
            AppLogger.health.info("Export cancelled")
        } catch {
            phase = .failed(error.localizedDescription)
            lastError = error.localizedDescription
            AppLogger.health.error("Export failed: \(error.localizedDescription)")
        }
    }

    private nonisolated func phaseLabel(for phase: ExportProgress.Phase) -> String {
        switch phase {
        case .workouts:    "workouts"
        case .sleep:       "sleep"
        case .heartRate:   "heart rate"
        case .respiration: "respiration"
        case .spo2:        "blood oxygen"
        case .steps:       "steps"
        case .intensity:   "active minutes"
        }
    }
}
