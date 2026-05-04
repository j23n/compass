import Foundation

// MARK: - Result types for monitoring data not present in CompassData

/// A monitoring interval from a monitoring FIT file (message 55).
/// Each record typically covers one minute of activity tracking.
public struct MonitoringInterval: Sendable, Equatable {
    public let timestamp: Date
    public let steps: Int
    /// Raw FIT activity_type enum (0=generic, 1=running, 2=cycling, 6=sedentary, 7=stop).
    public let activityType: Int
    /// 1 if the interval represents active time (activityType != 6 and != 7), else 0.
    public let intensityMinutes: Int
    public let activeCalories: Double

    public init(timestamp: Date, steps: Int, activityType: Int, intensityMinutes: Int, activeCalories: Double) {
        self.timestamp = timestamp
        self.steps = steps
        self.activityType = activityType
        self.intensityMinutes = intensityMinutes
        self.activeCalories = activeCalories
    }
}

/// A Body Battery energy-level sample from a monitoring FIT file.
public struct BodyBatterySample: Sendable, Equatable {
    public let timestamp: Date
    /// Current Body Battery level (0-100).
    public let level: Int
    /// Amount charged since last sample.
    public let charged: Int
    /// Amount drained since last sample.
    public let drained: Int

    public init(timestamp: Date, level: Int, charged: Int, drained: Int) {
        self.timestamp = timestamp
        self.level = level
        self.charged = charged
        self.drained = drained
    }
}

/// A respiration-rate sample from a monitoring FIT file.
public struct RespirationSample: Sendable, Equatable {
    public let timestamp: Date
    /// Breaths per minute.
    public let breathsPerMinute: Double

    public init(timestamp: Date, breathsPerMinute: Double) {
        self.timestamp = timestamp
        self.breathsPerMinute = breathsPerMinute
    }
}

/// A lightweight SpO₂ sample value (not tied to SwiftData).
public struct SpO2SampleValue: Sendable, Equatable {
    public let timestamp: Date
    /// SpO₂ percentage 0–100.
    public let percent: Int

    public init(timestamp: Date, percent: Int) {
        self.timestamp = timestamp
        self.percent = percent
    }
}

/// Aggregated results from parsing a monitoring FIT file.
public struct MonitoringData: Sendable {
    public let heartRateSamples: [HeartRateSampleValue]
    public let restingHeartRateSamples: [HeartRateSampleValue]
    public let stressSamples: [StressSampleValue]
    public let intervals: [MonitoringInterval]
    public let bodyBatterySamples: [BodyBatterySample]
    public let respirationSamples: [RespirationSample]
    public let spo2Samples: [SpO2SampleValue]
    /// Unique minute-start timestamps where any HR sample met the active-minute threshold.
    /// One entry per intensity-minute, dedup'd to the second-zero-of-the-minute.
    public let activeMinuteTimestamps: [Date]
    /// Day-start → total cumulative steps observed in this file (max across snapshots,
    /// summed across activity types). Authoritative for daily step totals; SyncCoordinator
    /// merges with previously-observed values via max.
    public let dailyStepTotals: [Date: Int]

    public init(
        heartRateSamples: [HeartRateSampleValue] = [],
        restingHeartRateSamples: [HeartRateSampleValue] = [],
        stressSamples: [StressSampleValue] = [],
        intervals: [MonitoringInterval] = [],
        bodyBatterySamples: [BodyBatterySample] = [],
        respirationSamples: [RespirationSample] = [],
        spo2Samples: [SpO2SampleValue] = [],
        activeMinuteTimestamps: [Date] = [],
        dailyStepTotals: [Date: Int] = [:]
    ) {
        self.heartRateSamples = heartRateSamples
        self.restingHeartRateSamples = restingHeartRateSamples
        self.stressSamples = stressSamples
        self.intervals = intervals
        self.bodyBatterySamples = bodyBatterySamples
        self.respirationSamples = respirationSamples
        self.spo2Samples = spo2Samples
        self.activeMinuteTimestamps = activeMinuteTimestamps
        self.dailyStepTotals = dailyStepTotals
    }
}

/// A lightweight heart-rate value (not tied to SwiftData).
public struct HeartRateSampleValue: Sendable, Equatable {
    public let timestamp: Date
    public let bpm: Int

    public init(timestamp: Date, bpm: Int) {
        self.timestamp = timestamp
        self.bpm = bpm
    }
}

/// A lightweight stress-score value (not tied to SwiftData).
public struct StressSampleValue: Sendable, Equatable {
    public let timestamp: Date
    public let stressScore: Int

    public init(timestamp: Date, stressScore: Int) {
        self.timestamp = timestamp
        self.stressScore = stressScore
    }
}
