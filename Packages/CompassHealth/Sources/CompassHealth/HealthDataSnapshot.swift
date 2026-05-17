import Foundation
import CompassData

/// Sendable value-type snapshot of the SwiftData rows that the exporter writes
/// into HealthKit. Built on the main actor from `@Model` instances and then
/// handed to the exporter actor — `@Model` types must never cross actor
/// boundaries so we project them into these plain structs first.
public struct HealthDataSnapshot: Sendable {
    public var device: DeviceSnapshot?
    public var activities: [ActivitySnapshot]
    public var sleepSessions: [SleepSnapshot]
    public var heartRates: [QuantityPoint]
    public var restingHeartRates: [QuantityPoint]
    public var respirations: [QuantityPoint]
    public var spo2s: [QuantityPoint]
    public var stepSamples: [QuantityPoint]
    public var intensitySamples: [QuantityPoint]

    public init(
        device: DeviceSnapshot? = nil,
        activities: [ActivitySnapshot] = [],
        sleepSessions: [SleepSnapshot] = [],
        heartRates: [QuantityPoint] = [],
        restingHeartRates: [QuantityPoint] = [],
        respirations: [QuantityPoint] = [],
        spo2s: [QuantityPoint] = [],
        stepSamples: [QuantityPoint] = [],
        intensitySamples: [QuantityPoint] = []
    ) {
        self.device = device
        self.activities = activities
        self.sleepSessions = sleepSessions
        self.heartRates = heartRates
        self.restingHeartRates = restingHeartRates
        self.respirations = respirations
        self.spo2s = spo2s
        self.stepSamples = stepSamples
        self.intensitySamples = intensitySamples
    }

    /// Total number of HealthKit objects this snapshot will produce. Used for
    /// progress reporting.
    public var totalCount: Int {
        let routePoints = activities.reduce(0) { $0 + $1.trackPoints.count }
        let workoutHR = activities.reduce(0) { $0 + $1.trackPoints.filter { $0.heartRate != nil }.count }
        let sleepStages = sleepSessions.reduce(0) { $0 + $1.stages.count + 1 /* inBed */ }
        return activities.count
            + routePoints
            + workoutHR
            + sleepStages
            + heartRates.count
            + restingHeartRates.count
            + respirations.count
            + spo2s.count
            + stepSamples.count
            + intensitySamples.count
    }

    public var isEmpty: Bool { totalCount == 0 }
}

public struct DeviceSnapshot: Sendable {
    public let name: String
    public let model: String
    public let localIdentifier: String?

    public init(name: String, model: String, localIdentifier: String?) {
        self.name = name
        self.model = model
        self.localIdentifier = localIdentifier
    }
}

public struct ActivitySnapshot: Sendable, Identifiable {
    public let id: UUID
    public let sport: Sport
    public let startDate: Date
    public let endDate: Date
    public let distance: Double
    public let duration: TimeInterval
    public let activeCalories: Double?
    public let totalAscent: Double?
    public let totalDescent: Double?
    public let pauses: [DateInterval]
    public let trackPoints: [TrackPointSnapshot]
    public let sourceFileName: String?

    public init(
        id: UUID,
        sport: Sport,
        startDate: Date,
        endDate: Date,
        distance: Double,
        duration: TimeInterval,
        activeCalories: Double?,
        totalAscent: Double?,
        totalDescent: Double?,
        pauses: [DateInterval],
        trackPoints: [TrackPointSnapshot],
        sourceFileName: String?
    ) {
        self.id = id
        self.sport = sport
        self.startDate = startDate
        self.endDate = endDate
        self.distance = distance
        self.duration = duration
        self.activeCalories = activeCalories
        self.totalAscent = totalAscent
        self.totalDescent = totalDescent
        self.pauses = pauses
        self.trackPoints = trackPoints
        self.sourceFileName = sourceFileName
    }
}

public struct TrackPointSnapshot: Sendable {
    public let timestamp: Date
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double?
    public let heartRate: Int?
    public let speed: Double?

    public init(timestamp: Date, latitude: Double, longitude: Double,
                altitude: Double?, heartRate: Int?, speed: Double?) {
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.heartRate = heartRate
        self.speed = speed
    }
}

public struct SleepSnapshot: Sendable, Identifiable {
    public let id: UUID
    public let startDate: Date
    public let endDate: Date
    public let stages: [StageSnapshot]

    public struct StageSnapshot: Sendable {
        public let startDate: Date
        public let endDate: Date
        public let stage: SleepStageType

        public init(startDate: Date, endDate: Date, stage: SleepStageType) {
            self.startDate = startDate
            self.endDate = endDate
            self.stage = stage
        }
    }

    public init(id: UUID, startDate: Date, endDate: Date, stages: [StageSnapshot]) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.stages = stages
    }
}

public struct QuantityPoint: Sendable {
    public let timestamp: Date
    public let value: Double

    public init(timestamp: Date, value: Double) {
        self.timestamp = timestamp
        self.value = value
    }
}
