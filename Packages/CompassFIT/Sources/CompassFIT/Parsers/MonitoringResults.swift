import Foundation

// MARK: - Result types for monitoring data not present in CompassData

/// A step-count observation from a monitoring FIT file.
public struct StepCount: Sendable, Equatable {
    public let timestamp: Date
    public let steps: Int

    public init(timestamp: Date, steps: Int) {
        self.timestamp = timestamp
        self.steps = steps
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

/// Aggregated results from parsing a monitoring FIT file.
public struct MonitoringData: Sendable {
    public let heartRateSamples: [HeartRateSampleValue]
    public let stressSamples: [StressSampleValue]
    public let stepCounts: [StepCount]
    public let bodyBatterySamples: [BodyBatterySample]
    public let respirationSamples: [RespirationSample]

    public init(
        heartRateSamples: [HeartRateSampleValue] = [],
        stressSamples: [StressSampleValue] = [],
        stepCounts: [StepCount] = [],
        bodyBatterySamples: [BodyBatterySample] = [],
        respirationSamples: [RespirationSample] = []
    ) {
        self.heartRateSamples = heartRateSamples
        self.stressSamples = stressSamples
        self.stepCounts = stepCounts
        self.bodyBatterySamples = bodyBatterySamples
        self.respirationSamples = respirationSamples
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
