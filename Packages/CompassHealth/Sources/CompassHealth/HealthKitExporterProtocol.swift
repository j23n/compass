import Foundation

/// Public surface of the HealthKit exporter. Lives in CompassHealth so the
/// app target depends on a protocol rather than the concrete actor — tests
/// substitute `MockHealthKitExporter` and the app uses
/// `HealthKitExporter`.
public protocol HealthKitExporterProtocol: Sendable, AnyObject {
    func isAvailable() -> Bool
    func requestAuthorization() async throws -> HealthAuthorizationResult

    /// Export everything in the snapshot. Idempotent — re-running produces
    /// no new HK samples because every write carries a stable
    /// `HKMetadataKeySyncIdentifier`. Reports progress as it goes;
    /// `progress` is invoked from the actor's executor.
    @discardableResult
    func export(
        snapshot: HealthDataSnapshot,
        progress: @Sendable (ExportProgress) -> Void
    ) async throws -> ExportSummary

    /// Deletes every Compass-sourced sample from HealthKit. Scoped to the
    /// app's own `HKSource` via `predicateForObjects(from:)` — non-Compass
    /// data is never touched.
    @discardableResult
    func deleteAllCompassData() async throws -> DeletionSummary
}

public struct ExportProgress: Sendable {
    public enum Phase: Sendable, Equatable {
        case workouts
        case sleep
        case heartRate
        case respiration
        case spo2
        case steps
        case intensity
    }

    public let phase: Phase
    public let done: Int
    public let total: Int

    public init(phase: Phase, done: Int, total: Int) {
        self.phase = phase
        self.done = done
        self.total = total
    }
}

public struct ExportSummary: Sendable, Codable, Equatable {
    public var workoutsAdded: Int
    public var routesAdded: Int
    public var sleepStagesAdded: Int
    public var quantitySamplesAdded: Int
    public var perTypeFailures: [String: Int]

    public init(
        workoutsAdded: Int = 0,
        routesAdded: Int = 0,
        sleepStagesAdded: Int = 0,
        quantitySamplesAdded: Int = 0,
        perTypeFailures: [String: Int] = [:]
    ) {
        self.workoutsAdded = workoutsAdded
        self.routesAdded = routesAdded
        self.sleepStagesAdded = sleepStagesAdded
        self.quantitySamplesAdded = quantitySamplesAdded
        self.perTypeFailures = perTypeFailures
    }

    public var totalAdded: Int {
        workoutsAdded + routesAdded + sleepStagesAdded + quantitySamplesAdded
    }
}

public struct DeletionSummary: Sendable, Codable, Equatable {
    public var perType: [String: Int]

    public init(perType: [String: Int] = [:]) {
        self.perType = perType
    }

    public var total: Int { perType.values.reduce(0, +) }
}

public enum HealthKitExporterError: Error, Sendable, Equatable {
    case unavailable
    case authorizationFailed(String)
    case writeFailed(typeIdentifier: String, underlying: String)
}
