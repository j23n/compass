#if canImport(HealthKit)
import HealthKit
import Foundation

/// Outcome of the system permission sheet. HealthKit deliberately does not
/// expose per-type read/share state; the best we can infer is that the user
/// closed the sheet. The exporter has to attempt writes and treat
/// `errorAuthorizationDenied` per-type at save time.
public enum HealthAuthorizationResult: Sendable, Equatable {
    case authorized       // sheet completed; we'll find out the rest on first write
    case denied           // HKHealthStore.isHealthDataAvailable() but request threw
    case unavailable      // !HKHealthStore.isHealthDataAvailable()
}

/// Catalogue of the HK types Compass writes. Centralised so the
/// authorization request, the wipe-all reconcile, and tests can iterate the
/// same list. Order is irrelevant — HK treats the set as unordered.
public enum HealthKitTypes {
    public static var writeTypes: Set<HKSampleType> {
        // HRV is intentionally omitted in MVP — Garmin emits RMSSD and
        // HealthKit only ships SDNN. Add `.heartRateVariabilitySDNN` here
        // when the exporter starts writing it.
        [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute(),
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!,
            HKObjectType.quantityType(forIdentifier: .heartRate)!,
            HKObjectType.quantityType(forIdentifier: .restingHeartRate)!,
            HKObjectType.quantityType(forIdentifier: .respiratoryRate)!,
            HKObjectType.quantityType(forIdentifier: .oxygenSaturation)!,
            HKObjectType.quantityType(forIdentifier: .stepCount)!,
            HKObjectType.quantityType(forIdentifier: .appleExerciseTime)!,
            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!,
            HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning)!,
            HKObjectType.quantityType(forIdentifier: .distanceCycling)!,
            HKObjectType.quantityType(forIdentifier: .distanceSwimming)!,
        ]
    }

    /// Sample types we know how to delete during reconciliation. Same set as
    /// `writeTypes` minus `workoutRoute` (HK cascade-deletes routes when the
    /// parent workout is deleted, but we list it for clarity).
    public static var deletableTypes: [HKSampleType] {
        Array(writeTypes)
    }
}
#endif
