#if canImport(HealthKit)
import Foundation
import HealthKit
import CoreLocation
import CompassData

/// One-way exporter from CompassData/SwiftData → HealthKit. Actor-isolated
/// because HealthKit callbacks arrive on arbitrary queues and the wipe /
/// rewrite reconcile path mutates state across many awaits. Snapshot rows
/// are passed in by value — `@Model` instances must stay on the main actor.
public actor HealthKitExporter: HealthKitExporterProtocol {

    private let store: HKHealthStore
    private let logSink: @Sendable (String) -> Void

    /// Cached HKDevice keyed by name+model. Built lazily from the snapshot
    /// so every workout / sample is attributed to the right Garmin device.
    private var deviceCache: [String: HKDevice] = [:]

    public init(logSink: @escaping @Sendable (String) -> Void = { _ in }) {
        self.store = HKHealthStore()
        self.logSink = logSink
    }

    // MARK: - Availability + authorization

    public nonisolated func isAvailable() -> Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    public func requestAuthorization() async throws -> HealthAuthorizationResult {
        guard HKHealthStore.isHealthDataAvailable() else {
            return .unavailable
        }
        do {
            try await store.requestAuthorization(toShare: HealthKitTypes.writeTypes,
                                                 read: [])
            return .authorized
        } catch {
            logSink("Authorization request threw: \(error.localizedDescription)")
            return .denied
        }
    }

    // MARK: - Export entry point

    @discardableResult
    public func export(
        snapshot: HealthDataSnapshot,
        progress: @Sendable (ExportProgress) -> Void
    ) async throws -> ExportSummary {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitExporterError.unavailable
        }

        var summary = ExportSummary()
        let device = snapshot.device.map { hkDevice(for: $0) }

        try await exportWorkouts(snapshot.activities, device: device, into: &summary, progress: progress)
        try await exportSleepSessions(snapshot.sleepSessions, device: device, into: &summary, progress: progress)

        try await exportQuantity(
            points: snapshot.heartRates,
            type: HKQuantityType(.heartRate),
            unit: .count().unitDivided(by: .minute()),
            identifier: SyncIdentifier.heartRate,
            phase: .heartRate,
            device: device,
            instantaneous: true,
            into: &summary,
            progress: progress
        )

        try await exportRestingHeartRate(snapshot.restingHeartRates, device: device, into: &summary, progress: progress)

        try await exportQuantity(
            points: snapshot.respirations,
            type: HKQuantityType(.respiratoryRate),
            unit: .count().unitDivided(by: .minute()),
            identifier: SyncIdentifier.respiration,
            phase: .respiration,
            device: device,
            instantaneous: true,
            into: &summary,
            progress: progress
        )

        // SpO2 in HealthKit is a fraction 0...1, not a percent. The
        // QuantityPoint value here is the raw percent (matches
        // `SpO2Sample.percent`); divide before writing.
        try await exportQuantity(
            points: snapshot.spo2s.map { QuantityPoint(timestamp: $0.timestamp, value: $0.value / 100.0) },
            type: HKQuantityType(.oxygenSaturation),
            unit: .percent(),
            identifier: SyncIdentifier.spo2,
            phase: .spo2,
            device: device,
            instantaneous: true,
            into: &summary,
            progress: progress
        )

        try await exportQuantity(
            points: snapshot.stepSamples,
            type: HKQuantityType(.stepCount),
            unit: .count(),
            identifier: SyncIdentifier.step,
            phase: .steps,
            device: device,
            instantaneous: false,
            windowDuration: 60,
            into: &summary,
            progress: progress
        )

        try await exportQuantity(
            points: snapshot.intensitySamples,
            type: HKQuantityType(.appleExerciseTime),
            unit: .minute(),
            identifier: SyncIdentifier.intensity,
            phase: .intensity,
            device: device,
            instantaneous: false,
            windowDuration: 60,
            into: &summary,
            progress: progress
        )

        logSink("Export complete: \(summary.totalAdded) HK objects added")
        return summary
    }

    // MARK: - Workouts

    private func exportWorkouts(
        _ activities: [ActivitySnapshot],
        device: HKDevice?,
        into summary: inout ExportSummary,
        progress: @Sendable (ExportProgress) -> Void
    ) async throws {
        let total = activities.count
        progress(ExportProgress(phase: .workouts, done: 0, total: total))

        for (index, activity) in activities.enumerated() {
            try Task.checkCancellation()
            do {
                try await exportSingleWorkout(activity, device: device, into: &summary)
            } catch {
                logSink("Workout export failed (\(activity.sport) @ \(activity.startDate)): \(error.localizedDescription)")
                summary.perTypeFailures["workout", default: 0] += 1
            }
            progress(ExportProgress(phase: .workouts, done: index + 1, total: total))
        }
    }

    private func exportSingleWorkout(
        _ activity: ActivitySnapshot,
        device: HKDevice?,
        into summary: inout ExportSummary
    ) async throws {
        let config = HKWorkoutConfiguration()
        config.activityType = activity.sport.hkActivityType
        config.locationType = activity.sport.hkLocationType
        config.swimmingLocationType = .unknown

        let builder = HKWorkoutBuilder(healthStore: store,
                                       configuration: config,
                                       device: device)

        do {
            try await populateAndFinish(builder: builder, activity: activity, device: device, summary: &summary)
        } catch {
            builder.discardWorkout()
            throw error
        }
    }

    private func populateAndFinish(
        builder: HKWorkoutBuilder,
        activity: ActivitySnapshot,
        device: HKDevice?,
        summary: inout ExportSummary
    ) async throws {
        try await builder.beginCollection(at: activity.startDate)

        if !activity.pauses.isEmpty {
            var events: [HKWorkoutEvent] = []
            for pause in activity.pauses {
                events.append(HKWorkoutEvent(
                    type: .pause,
                    dateInterval: DateInterval(start: pause.start, duration: 0),
                    metadata: nil
                ))
                events.append(HKWorkoutEvent(
                    type: .resume,
                    dateInterval: DateInterval(start: pause.end, duration: 0),
                    metadata: nil
                ))
            }
            try await builder.addWorkoutEvents(events)
        }

        // Per-trackpoint HR samples. HealthKit dedupes by sync identifier so
        // we can re-export the same workout safely.
        let hrType = HKQuantityType(.heartRate)
        let bpmUnit = HKUnit.count().unitDivided(by: .minute())
        let hrSamples: [HKQuantitySample] = activity.trackPoints.compactMap { tp in
            guard let bpm = tp.heartRate, bpm > 0 else { return nil }
            let metadata: [String: Any] = [
                HKMetadataKeySyncIdentifier: SyncIdentifier.workoutHeartRate(
                    sport: activity.sport,
                    startDate: activity.startDate,
                    sampleDate: tp.timestamp
                ),
                HKMetadataKeySyncVersion: CompassExportSchemaVersion.current,
                HKMetadataKeyWasUserEntered: false,
            ]
            return HKQuantitySample(
                type: hrType,
                quantity: HKQuantity(unit: bpmUnit, doubleValue: Double(bpm)),
                start: tp.timestamp,
                end: tp.timestamp,
                device: device,
                metadata: metadata
            )
        }
        if !hrSamples.isEmpty {
            for chunk in hrSamples.chunked(into: 1000) {
                try await builder.addSamples(chunk as [HKSample])
            }
            summary.quantitySamplesAdded += hrSamples.count
        }

        // Active energy as a single sample spanning the workout
        if let cal = activity.activeCalories, cal > 0 {
            let energy = HKQuantitySample(
                type: HKQuantityType(.activeEnergyBurned),
                quantity: HKQuantity(unit: .kilocalorie(), doubleValue: cal),
                start: activity.startDate,
                end: activity.endDate,
                device: device,
                metadata: [
                    HKMetadataKeySyncIdentifier: SyncIdentifier.workoutEnergy(sport: activity.sport, startDate: activity.startDate),
                    HKMetadataKeySyncVersion: CompassExportSchemaVersion.current,
                    HKMetadataKeyWasUserEntered: false,
                ]
            )
            try await builder.addSamples([energy] as [HKSample])
        }

        if let distType = activity.sport.hkDistanceType, activity.distance > 0 {
            let dist = HKQuantitySample(
                type: distType,
                quantity: HKQuantity(unit: .meter(), doubleValue: activity.distance),
                start: activity.startDate,
                end: activity.endDate,
                device: device,
                metadata: [
                    HKMetadataKeySyncIdentifier: SyncIdentifier.workoutDistance(sport: activity.sport, startDate: activity.startDate),
                    HKMetadataKeySyncVersion: CompassExportSchemaVersion.current,
                    HKMetadataKeyWasUserEntered: false,
                ]
            )
            try await builder.addSamples([dist] as [HKSample])
        }

        try await builder.endCollection(at: activity.endDate)

        let workoutMetadata: [String: Any] = [
            HKMetadataKeyExternalUUID: activity.id.uuidString,
            HKMetadataKeySyncIdentifier: SyncIdentifier.workout(sport: activity.sport, startDate: activity.startDate),
            HKMetadataKeySyncVersion: CompassExportSchemaVersion.current,
            HKMetadataKeyWasUserEntered: false,
            "compass.sourceFile": activity.sourceFileName ?? "",
            "compass.sportRaw": activity.sport.rawValue,
        ]
        try await builder.addMetadata(workoutMetadata)

        guard let workout = try await builder.finishWorkout() else {
            throw HealthKitExporterError.writeFailed(
                typeIdentifier: HKObjectType.workoutType().identifier,
                underlying: "finishWorkout returned nil"
            )
        }
        summary.workoutsAdded += 1

        // Route — only if there's at least one GPS point
        let gpsPoints = activity.trackPoints.filter { $0.latitude != 0 || $0.longitude != 0 }
        if !gpsPoints.isEmpty {
            try await exportRoute(for: workout, trackPoints: gpsPoints, device: device)
            summary.routesAdded += 1
        }
    }

    private func exportRoute(
        for workout: HKWorkout,
        trackPoints: [TrackPointSnapshot],
        device: HKDevice?
    ) async throws {
        let routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: device)

        let locations: [CLLocation] = trackPoints.map { tp in
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: tp.latitude, longitude: tp.longitude),
                altitude: tp.altitude ?? 0,
                horizontalAccuracy: 5,
                verticalAccuracy: tp.altitude == nil ? -1 : 10,
                course: -1,
                speed: tp.speed ?? -1,
                timestamp: tp.timestamp
            )
        }

        for chunk in locations.chunked(into: 1000) {
            try await routeBuilder.insertRouteData(chunk)
        }

        _ = try await routeBuilder.finishRoute(with: workout, metadata: [
            HKMetadataKeySyncIdentifier: SyncIdentifier.workoutRoute(
                sport: workoutSport(workout) ?? .other,
                startDate: workout.startDate
            ),
            HKMetadataKeySyncVersion: CompassExportSchemaVersion.current,
        ])
    }

    private nonisolated func workoutSport(_ workout: HKWorkout) -> Sport? {
        Sport(rawValue: (workout.metadata?["compass.sportRaw"] as? String) ?? "")
    }

    // MARK: - Sleep

    private func exportSleepSessions(
        _ sessions: [SleepSnapshot],
        device: HKDevice?,
        into summary: inout ExportSummary,
        progress: @Sendable (ExportProgress) -> Void
    ) async throws {
        let total = sessions.reduce(0) { $0 + $1.stages.count + 1 }
        var done = 0
        progress(ExportProgress(phase: .sleep, done: 0, total: total))

        let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!

        for session in sessions {
            try Task.checkCancellation()
            var samples: [HKCategorySample] = []

            // Wrapping inBed sample for the whole session
            let inBedMetadata: [String: Any] = [
                HKMetadataKeySyncIdentifier: SyncIdentifier.sleepInBed(startDate: session.startDate),
                HKMetadataKeySyncVersion: CompassExportSchemaVersion.current,
                HKMetadataKeyWasUserEntered: false,
            ]
            samples.append(HKCategorySample(
                type: sleepType,
                value: HKCategoryValueSleepAnalysis.inBed.rawValue,
                start: session.startDate,
                end: session.endDate,
                device: device,
                metadata: inBedMetadata
            ))

            for stage in session.stages where stage.endDate > stage.startDate {
                let metadata: [String: Any] = [
                    HKMetadataKeySyncIdentifier: SyncIdentifier.sleepStage(
                        sessionStart: session.startDate,
                        stageStart: stage.startDate
                    ),
                    HKMetadataKeySyncVersion: CompassExportSchemaVersion.current,
                    HKMetadataKeyWasUserEntered: false,
                ]
                samples.append(HKCategorySample(
                    type: sleepType,
                    value: stage.stage.hkSleepValue.rawValue,
                    start: stage.startDate,
                    end: stage.endDate,
                    device: device,
                    metadata: metadata
                ))
            }

            do {
                try await save(samples as [HKObject])
                summary.sleepStagesAdded += samples.count
            } catch {
                logSink("Sleep export failed for session \(session.startDate): \(error.localizedDescription)")
                summary.perTypeFailures["sleepAnalysis", default: 0] += samples.count
            }

            done += samples.count
            progress(ExportProgress(phase: .sleep, done: done, total: total))
        }
    }

    // MARK: - Continuous quantity samples

    private func exportQuantity(
        points: [QuantityPoint],
        type: HKQuantityType,
        unit: HKUnit,
        identifier: (Date) -> String,
        phase: ExportProgress.Phase,
        device: HKDevice?,
        instantaneous: Bool,
        windowDuration: TimeInterval = 0,
        into summary: inout ExportSummary,
        progress: @Sendable (ExportProgress) -> Void
    ) async throws {
        let total = points.count
        progress(ExportProgress(phase: phase, done: 0, total: total))
        guard total > 0 else { return }

        var done = 0
        for chunk in points.chunked(into: 1000) {
            try Task.checkCancellation()
            let samples: [HKQuantitySample] = chunk.map { point in
                let end = instantaneous ? point.timestamp : point.timestamp.addingTimeInterval(windowDuration)
                let metadata: [String: Any] = [
                    HKMetadataKeySyncIdentifier: identifier(point.timestamp),
                    HKMetadataKeySyncVersion: CompassExportSchemaVersion.current,
                    HKMetadataKeyWasUserEntered: false,
                ]
                return HKQuantitySample(
                    type: type,
                    quantity: HKQuantity(unit: unit, doubleValue: point.value),
                    start: point.timestamp,
                    end: end,
                    device: device,
                    metadata: metadata
                )
            }
            do {
                try await save(samples as [HKObject])
                summary.quantitySamplesAdded += samples.count
            } catch {
                logSink("\(type.identifier) save failed: \(error.localizedDescription)")
                summary.perTypeFailures[type.identifier, default: 0] += samples.count
            }
            done += chunk.count
            progress(ExportProgress(phase: phase, done: done, total: total))
        }
    }

    private func exportRestingHeartRate(
        _ points: [QuantityPoint],
        device: HKDevice?,
        into summary: inout ExportSummary,
        progress: @Sendable (ExportProgress) -> Void
    ) async throws {
        try await exportQuantity(
            points: points,
            type: HKQuantityType(.restingHeartRate),
            unit: .count().unitDivided(by: .minute()),
            identifier: SyncIdentifier.restingHeartRate,
            phase: .heartRate,
            device: device,
            instantaneous: true,
            into: &summary,
            progress: progress
        )
    }

    // MARK: - Reconciliation (wipe-and-rewrite for parser changes)

    @discardableResult
    public func deleteAllCompassData() async throws -> DeletionSummary {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitExporterError.unavailable
        }
        let source = HKSource.default()
        let predicate = HKQuery.predicateForObjects(from: [source])

        var summary = DeletionSummary()
        for type in HealthKitTypes.deletableTypes {
            do {
                let deleted = try await store.deleteObjects(of: type, predicate: predicate)
                summary.perType[type.identifier] = deleted
            } catch {
                logSink("Delete failed for \(type.identifier): \(error.localizedDescription)")
                summary.perType[type.identifier] = 0
            }
        }
        logSink("deleteAllCompassData removed \(summary.total) objects across \(summary.perType.count) types")
        return summary
    }

    // MARK: - Internal helpers

    private func save(_ objects: [HKObject]) async throws {
        guard !objects.isEmpty else { return }
        try await store.save(objects)
    }

    private func hkDevice(for snapshot: DeviceSnapshot) -> HKDevice {
        let key = "\(snapshot.name)|\(snapshot.model)"
        if let cached = deviceCache[key] { return cached }
        let device = HKDevice(
            name: snapshot.name,
            manufacturer: "Garmin",
            model: snapshot.model,
            hardwareVersion: nil,
            firmwareVersion: nil,
            softwareVersion: nil,
            localIdentifier: snapshot.localIdentifier,
            udiDeviceIdentifier: nil
        )
        deviceCache[key] = device
        return device
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
#endif
