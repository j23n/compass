import Foundation
import CompassData

/// Stable HealthKit sync-identifier helpers. Identifiers are derived from
/// *natural keys* (sport + start epoch, timestamp epoch, …) rather than
/// SwiftData UUIDs, so the same logical sample produces the same identifier
/// across reparse runs. The Compass export schema version is captured in
/// `CompassExportSchemaVersion.current`; bump it whenever the identifier
/// shape (or the mapping that produces samples) changes.
public enum SyncIdentifier {

    private static let prefix = "compass"

    private static func epoch(_ date: Date) -> Int { Int(date.timeIntervalSince1970) }

    public static func workout(sport: Sport, startDate: Date) -> String {
        "\(prefix).workout.\(sport.rawValue).\(epoch(startDate))"
    }

    public static func workoutRoute(sport: Sport, startDate: Date) -> String {
        "\(prefix).route.\(sport.rawValue).\(epoch(startDate))"
    }

    public static func workoutHeartRate(sport: Sport, startDate: Date, sampleDate: Date) -> String {
        "\(prefix).workout.hr.\(sport.rawValue).\(epoch(startDate)).\(epoch(sampleDate))"
    }

    public static func workoutDistance(sport: Sport, startDate: Date) -> String {
        "\(prefix).workout.dist.\(sport.rawValue).\(epoch(startDate))"
    }

    public static func workoutEnergy(sport: Sport, startDate: Date) -> String {
        "\(prefix).workout.kcal.\(sport.rawValue).\(epoch(startDate))"
    }

    public static func sleepInBed(startDate: Date) -> String {
        "\(prefix).sleep.inbed.\(epoch(startDate))"
    }

    public static func sleepStage(sessionStart: Date, stageStart: Date) -> String {
        "\(prefix).sleep.stage.\(epoch(sessionStart)).\(epoch(stageStart))"
    }

    public static func heartRate(at date: Date) -> String {
        "\(prefix).hr.\(epoch(date))"
    }

    public static func restingHeartRate(at date: Date) -> String {
        "\(prefix).hr.rest.\(epoch(date))"
    }

    public static func respiration(at date: Date) -> String {
        "\(prefix).resp.\(epoch(date))"
    }

    public static func spo2(at date: Date) -> String {
        "\(prefix).spo2.\(epoch(date))"
    }

    public static func step(at date: Date) -> String {
        "\(prefix).step.\(epoch(date))"
    }

    public static func intensity(at date: Date) -> String {
        "\(prefix).intensity.\(epoch(date))"
    }
}

/// Versions the *shape* of everything Task 10 wipes-and-rewrites. Bump on:
///   - natural-key changes (e.g. sport→startDate→identifier)
///   - new sample types
///   - stage→HK value mapping changes
///   - metadata key naming changes
public enum CompassExportSchemaVersion {
    public static let current: Int = 1
}
