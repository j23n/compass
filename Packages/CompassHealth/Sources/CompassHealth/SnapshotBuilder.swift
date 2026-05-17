import Foundation
import SwiftData
import CompassData

/// Builds a `HealthDataSnapshot` from a SwiftData `ModelContext` by reading
/// rows on the calling actor (must be the main actor — `@Model` instances
/// are bound to their context's actor) and projecting them into Sendable
/// value types that the exporter actor can consume.
@MainActor
public enum HealthSnapshotBuilder {

    /// Builds a full snapshot. Optional `since` restricts each window to
    /// rows newer than the cursor; nil means "everything in SwiftData".
    public static func build(
        context: ModelContext,
        since: Date? = nil
    ) -> HealthDataSnapshot {
        HealthDataSnapshot(
            device: fetchDevice(context: context),
            activities: fetchActivities(context: context, since: since),
            sleepSessions: fetchSleepSessions(context: context, since: since),
            heartRates: fetchHeartRates(context: context, selector: .nonResting, since: since),
            restingHeartRates: fetchHeartRates(context: context, selector: .resting, since: since),
            respirations: fetchRespirations(context: context, since: since),
            spo2s: fetchSpO2(context: context, since: since),
            stepSamples: fetchStepSamples(context: context, since: since),
            intensitySamples: fetchIntensity(context: context, since: since)
        )
    }

    // MARK: - Device

    private static func fetchDevice(context: ModelContext) -> DeviceSnapshot? {
        let descriptor = FetchDescriptor<ConnectedDevice>(sortBy: [SortDescriptor(\.name)])
        guard let device = try? context.fetch(descriptor).first else { return nil }
        return DeviceSnapshot(
            name: device.name,
            model: device.model,
            localIdentifier: device.peripheralIdentifier?.uuidString
        )
    }

    // MARK: - Activities

    private static func fetchActivities(context: ModelContext, since: Date?) -> [ActivitySnapshot] {
        let predicate: Predicate<Activity>? = since.map { since in
            #Predicate<Activity> { $0.startDate >= since }
        }
        var descriptor = FetchDescriptor<Activity>(predicate: predicate,
                                                   sortBy: [SortDescriptor(\.startDate)])
        descriptor.relationshipKeyPathsForPrefetching = [\.trackPoints]
        guard let rows = try? context.fetch(descriptor) else { return [] }

        return rows.map { activity in
            let trackPoints: [TrackPointSnapshot] = activity.trackPoints
                .sorted { $0.timestamp < $1.timestamp }
                .map {
                    TrackPointSnapshot(
                        timestamp: $0.timestamp,
                        latitude: $0.latitude,
                        longitude: $0.longitude,
                        altitude: $0.altitude,
                        heartRate: $0.heartRate,
                        speed: $0.speed
                    )
                }
            let pauses = activity.pauses
            return ActivitySnapshot(
                id: activity.id,
                sport: activity.sport,
                startDate: activity.startDate,
                endDate: activity.endDate,
                distance: activity.distance,
                duration: activity.duration,
                activeCalories: activity.activeCalories,
                totalAscent: activity.totalAscent,
                totalDescent: activity.totalDescent,
                pauses: pauses,
                trackPoints: trackPoints,
                sourceFileName: activity.sourceFileName
            )
        }
    }

    // MARK: - Sleep

    private static func fetchSleepSessions(context: ModelContext, since: Date?) -> [SleepSnapshot] {
        let predicate: Predicate<SleepSession>? = since.map { since in
            #Predicate<SleepSession> { $0.startDate >= since }
        }
        var descriptor = FetchDescriptor<SleepSession>(predicate: predicate,
                                                       sortBy: [SortDescriptor(\.startDate)])
        descriptor.relationshipKeyPathsForPrefetching = [\.stages]
        guard let rows = try? context.fetch(descriptor) else { return [] }

        return rows.map { session in
            let stages: [SleepSnapshot.StageSnapshot] = session.stages
                .sorted { $0.startDate < $1.startDate }
                .map { SleepSnapshot.StageSnapshot(
                    startDate: $0.startDate,
                    endDate: $0.endDate,
                    stage: $0.stage
                ) }
            return SleepSnapshot(
                id: session.id,
                startDate: session.startDate,
                endDate: session.endDate,
                stages: stages
            )
        }
    }

    // MARK: - Heart rate

    private enum HRSelector { case resting, nonResting }

    private static func fetchHeartRates(
        context: ModelContext,
        selector: HRSelector,
        since: Date?
    ) -> [QuantityPoint] {
        let restingContext = HeartRateContext.resting
        let predicate: Predicate<HeartRateSample>?
        switch (selector, since) {
        case (.resting, .some(let cutoff)):
            predicate = #Predicate { $0.context == restingContext && $0.timestamp >= cutoff }
        case (.resting, .none):
            predicate = #Predicate { $0.context == restingContext }
        case (.nonResting, .some(let cutoff)):
            predicate = #Predicate { $0.context != restingContext && $0.timestamp >= cutoff }
        case (.nonResting, .none):
            predicate = #Predicate { $0.context != restingContext }
        }
        let descriptor = FetchDescriptor<HeartRateSample>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.timestamp)]
        )
        guard let rows = try? context.fetch(descriptor) else { return [] }
        return rows.map { QuantityPoint(timestamp: $0.timestamp, value: Double($0.bpm)) }
    }

    // MARK: - Respiration

    private static func fetchRespirations(context: ModelContext, since: Date?) -> [QuantityPoint] {
        let predicate: Predicate<RespirationSample>? = since.map { cutoff in
            #Predicate<RespirationSample> { $0.timestamp >= cutoff }
        }
        let descriptor = FetchDescriptor<RespirationSample>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.timestamp)]
        )
        guard let rows = try? context.fetch(descriptor) else { return [] }
        return rows.map { QuantityPoint(timestamp: $0.timestamp, value: $0.breathsPerMinute) }
    }

    // MARK: - SpO2

    private static func fetchSpO2(context: ModelContext, since: Date?) -> [QuantityPoint] {
        let predicate: Predicate<SpO2Sample>? = since.map { cutoff in
            #Predicate<SpO2Sample> { $0.timestamp >= cutoff }
        }
        let descriptor = FetchDescriptor<SpO2Sample>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.timestamp)]
        )
        guard let rows = try? context.fetch(descriptor) else { return [] }
        return rows.map { QuantityPoint(timestamp: $0.timestamp, value: Double($0.percent)) }
    }

    // MARK: - Steps

    private static func fetchStepSamples(context: ModelContext, since: Date?) -> [QuantityPoint] {
        let predicate: Predicate<StepSample>? = since.map { cutoff in
            #Predicate<StepSample> { $0.timestamp >= cutoff }
        }
        let descriptor = FetchDescriptor<StepSample>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.timestamp)]
        )
        guard let rows = try? context.fetch(descriptor) else { return [] }
        return rows
            .filter { $0.steps > 0 }
            .map { QuantityPoint(timestamp: $0.timestamp, value: Double($0.steps)) }
    }

    // MARK: - Intensity / active minutes

    private static func fetchIntensity(context: ModelContext, since: Date?) -> [QuantityPoint] {
        let predicate: Predicate<IntensitySample>? = since.map { cutoff in
            #Predicate<IntensitySample> { $0.timestamp >= cutoff }
        }
        let descriptor = FetchDescriptor<IntensitySample>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.timestamp)]
        )
        guard let rows = try? context.fetch(descriptor) else { return [] }
        return rows.map { QuantityPoint(timestamp: $0.timestamp, value: Double($0.minutes)) }
    }
}
