import Foundation
import os
import FitFileParser
import CompassData

/// Parses Garmin `/GARMIN/Monitor/*.fit` files and returns arrays of health samples.
///
/// - Monitoring messages (55) — step/activity interval data; compact HR variant (fields 26/27)
/// - Stress (227) — stress score samples
/// - Respiration (297) — breathing rate samples
/// - SpO₂ (305 / 269) — blood oxygen saturation
/// - HSA (306/307/308/314) — hsa_stress, hsa_respiration, hsa_heart_rate, hsa_body_battery
/// - Monitoring_v2 (233) — field dump until field map is confirmed
public struct MonitoringFITParser: Sendable {

    private static let logger = Logger(subsystem: "com.compass.fit", category: "MonitoringFITParser")

    // Activity types that contribute intensity minutes (purposeful movement only).
    // Used as fallback when HR data is unavailable.
    private static let intensityActivityTypes: Set<String> = [
        "running", "cycling", "fitness_equipment", "swimming", "walking"
    ]

    /// HR threshold for active / intensity minutes (beats per minute).
    /// Any interval where the heart rate ≥ this value counts as an intensity minute.
    private static let intensityHRThreshold: Int = 100

    private let profile: DeviceProfile

    public init(profile: DeviceProfile = .default) {
        self.profile = profile
    }

    /// Parses a monitoring FIT file and returns aggregated health data.
    ///
    /// - Parameter data: Raw bytes of the FIT file.
    /// - Returns: A ``MonitoringData`` value with all extracted samples.
    public func parse(data: Data) async throws -> MonitoringData {
        let fitFile = FitFile(data: data, parsingType: .generic)

        var heartRateSamples: [HeartRateSampleValue] = []
        var stressSamples: [StressSampleValue] = []
        var intervals: [MonitoringInterval] = []
        var bodyBatterySamples: [BodyBatterySample] = []
        var respirationSamples: [RespirationSample] = []
        var spo2Samples: [SpO2SampleValue] = []

        // Msg 55 `cycles` field is cumulative since midnight. Track per activity_type string.
        var lastCyclesByType: [String: Int] = [:]
        // Track last full Garmin-epoch timestamp seen (for timestamp_16 resolution).
        var lastFullTimestamp: UInt32 = 0
        // Track most recent HR per minute for active minutes threshold
        var recentHR: Int?

        for message in fitFile.messages {
            // Update running 32-bit timestamp from any message that carries one.
            if let date = message.interpretedField(key: "timestamp")?.time {
                lastFullTimestamp = UInt32(max(0, date.timeIntervalSince(FITTimestamp.epoch)))
            }

            // Track HR from any source for active minutes threshold
            if let hrVal = message.interpretedField(key: "heart_rate")?.value, hrVal > 0, hrVal != 255 {
                recentHR = Int(hrVal)
            }

            switch message.messageType {
            case .monitoring:
                if let hr = parseMonitoringHR(from: message, lastFullTimestamp: lastFullTimestamp) {
                    heartRateSamples.append(hr)
                    recentHR = hr.bpm
                }
                if let interval = parseMonitoringInterval(from: message, lastCycles: &lastCyclesByType, recentHR: recentHR) {
                    intervals.append(interval)
                }

            case .stress_level:
                if let stress = parseStress(from: message) {
                    stressSamples.append(stress)
                }

            case .respiration_rate:
                if let resp = parseRespiration(from: message) {
                    respirationSamples.append(resp)
                }

            case .hsa_heart_rate_data:
                let hsaHRs = parseHSAHeartRate(from: message)
                heartRateSamples.append(contentsOf: hsaHRs)
                if let last = hsaHRs.last { recentHR = last.bpm }

            case .hsa_stress_data:
                parseHSAStress(from: message, into: &stressSamples)

            case .hsa_respiration_data:
                parseHSARespiration(from: message, into: &respirationSamples)

            case .hsa_body_battery_data:
                parseHSABodyBattery(from: message, into: &bodyBatterySamples)

            case .hsa_spo2_data:
                parseHSASpO2(from: message, into: &spo2Samples)

            case .spo2_data:
                if let sample = parseSpO2(from: message) {
                    spo2Samples.append(sample)
                }

            default:
                break
            }
        }

        return MonitoringData(
            heartRateSamples: heartRateSamples,
            stressSamples: stressSamples,
            intervals: intervals,
            bodyBatterySamples: bodyBatterySamples,
            respirationSamples: respirationSamples,
            spo2Samples: spo2Samples
        )
    }

    // MARK: - Private helpers

    private func parseMonitoringInterval(
        from message: FitMessage,
        lastCycles: inout [String: Int],
        recentHR: Int?
    ) -> MonitoringInterval? {
        guard let timestamp = message.interpretedField(key: "timestamp")?.time else { return nil }

        let activityType = message.interpretedField(key: "activity_type")?.name ?? "generic"
        let isStepActivity = activityType == "walking" || activityType == "running"

        let steps: Int
        if isStepActivity {
            let cumulative = Int(message.interpretedField(key: "steps")?.value ?? 0)
            let prev = lastCycles[activityType] ?? 0
            let delta = cumulative >= prev ? cumulative - prev : cumulative
            lastCycles[activityType] = cumulative
            steps = delta
        } else {
            steps = 0
        }

        // Active / intensity minutes: prefer HR threshold, fall back to activity-type allowlist
        let intensityMinutes: Int
        if let hr = recentHR, hr >= Self.intensityHRThreshold {
            intensityMinutes = 1
        } else if recentHR == nil {
            // Fall back to activity-type allowlist when no HR data available
            intensityMinutes = Self.intensityActivityTypes.contains(activityType) ? 1 : 0
        } else {
            intensityMinutes = 0
        }

        let fv = message.interpretedField(key: "active_calories")
        let activeCalories = fv?.value ?? fv?.valueUnit?.value ?? 0.0

        return MonitoringInterval(
            timestamp: timestamp,
            steps: steps,
            activityType: activityTypeInt(activityType),
            intensityMinutes: intensityMinutes,
            activeCalories: activeCalories
        )
    }

    private func parseStress(from message: FitMessage) -> StressSampleValue? {
        let timestamp = message.interpretedField(key: "stress_level_time")?.time
                     ?? message.interpretedField(key: "timestamp")?.time
        guard let timestamp,
              let scoreVal = message.interpretedField(key: "stress_level_value")?.value else { return nil }
        let score = Int(scoreVal)
        guard score >= 0, score <= 100 else { return nil }
        return StressSampleValue(timestamp: timestamp, stressScore: score)
    }

    /// Extracts an HR sample from the compact HR variant of monitoring msg 55.
    private func parseMonitoringHR(
        from message: FitMessage,
        lastFullTimestamp: UInt32
    ) -> HeartRateSampleValue? {
        guard let hrVal = message.interpretedField(key: "heart_rate")?.value,
              hrVal > 0, hrVal != 255 else { return nil }
        let hr = Int(hrVal)

        if let date = message.interpretedField(key: "timestamp")?.time {
            return HeartRateSampleValue(timestamp: date, bpm: hr)
        }
        if let ts16Raw = message.interpretedField(key: "timestamp_16")?.value {
            let ts16 = UInt16(ts16Raw) & 0xFFFF
            let resolved = resolveTimestamp16(ts16, lastFull: lastFullTimestamp)
            return HeartRateSampleValue(timestamp: FITTimestamp.date(fromFITTimestamp: resolved), bpm: hr)
        }
        return nil
    }

    private func resolveTimestamp16(_ ts16: UInt16, lastFull: UInt32) -> UInt32 {
        let lastLow = lastFull & 0xFFFF
        var full = (lastFull & 0xFFFF0000) | UInt32(ts16)
        if UInt32(ts16) < lastLow {
            full = full &+ 0x10000
        }
        return full
    }

    // MARK: - HSA parsing helpers

    private func parseHSAHeartRate(from message: FitMessage) -> [HeartRateSampleValue] {
        guard let timestamp = message.interpretedField(key: "timestamp")?.time else { return [] }
        return parsePipeArray(from: message, key: "heart_rate").enumerated().compactMap { i, hr in
            guard hr > 0, hr != 255 else { return nil }
            return HeartRateSampleValue(timestamp: timestamp.addingTimeInterval(TimeInterval(i)), bpm: Int(hr))
        }
    }

    private func parseHSAStress(from message: FitMessage, into samples: inout [StressSampleValue]) {
        guard let timestamp = message.interpretedField(key: "timestamp")?.time else { return }
        for (i, stress) in parsePipeArray(from: message, key: "stress_level").enumerated() {
            guard stress >= 0 else { continue }
            samples.append(StressSampleValue(
                timestamp: timestamp.addingTimeInterval(TimeInterval(i)),
                stressScore: Int(stress)
            ))
        }
    }

    private func parseHSARespiration(from message: FitMessage, into samples: inout [RespirationSample]) {
        guard let timestamp = message.interpretedField(key: "timestamp")?.time else { return }
        for (i, rate) in parsePipeArray(from: message, key: "respiration_rate").enumerated() {
            guard rate > 0, rate != 255 else { continue }
            samples.append(RespirationSample(
                timestamp: timestamp.addingTimeInterval(TimeInterval(i)),
                breathsPerMinute: rate
            ))
        }
    }

    private func parseHSABodyBattery(from message: FitMessage, into samples: inout [BodyBatterySample]) {
        guard let timestamp = message.interpretedField(key: "timestamp")?.time else { return }
        for (i, level) in parsePipeArray(from: message, key: "level").enumerated() {
            guard level >= 0 else { continue }
            samples.append(BodyBatterySample(
                timestamp: timestamp.addingTimeInterval(TimeInterval(i)),
                level: Int(level),
                charged: 0,
                drained: 0
            ))
        }
    }

    private func parseHSASpO2(from message: FitMessage, into samples: inout [SpO2SampleValue]) {
        guard let timestamp = message.interpretedField(key: "timestamp")?.time else { return }
        for (i, reading) in parsePipeArray(from: message, key: "reading_spo2").enumerated() {
            let pct = Int(reading)
            guard pct >= 1, pct <= 100 else { continue }
            samples.append(SpO2SampleValue(
                timestamp: timestamp.addingTimeInterval(TimeInterval(i)),
                percent: pct
            ))
        }
    }

    private func parseSpO2(from message: FitMessage) -> SpO2SampleValue? {
        guard let timestamp = message.interpretedField(key: "timestamp")?.time else { return nil }
        guard let val = message.interpretedField(key: "reading_spo2")?.value else { return nil }
        let pct = Int(val)
        guard pct >= 1, pct <= 100 else { return nil }
        return SpO2SampleValue(timestamp: timestamp, percent: pct)
    }

    private func parseRespiration(from message: FitMessage) -> RespirationSample? {
        guard let timestamp = message.interpretedField(key: "timestamp")?.time else { return nil }
        let fv = message.interpretedField(key: "respiration_rate")
        guard let rate = fv?.valueUnit?.value ?? fv?.value, rate > 0 else { return nil }
        return RespirationSample(timestamp: timestamp, breathsPerMinute: rate)
    }

    // First element is dropped due to a bug in FitInterpretMesg.m — acceptable for 60-sample arrays.
    private func parsePipeArray(from message: FitMessage, key: String) -> [Double] {
        guard let str = message.interpretedField(key: key)?.name else { return [] }
        return str.split(separator: "|").compactMap { Double($0) }
    }

    private func activityTypeInt(_ name: String) -> Int {
        switch name {
        case "running":           return 1
        case "cycling":           return 2
        case "transition":        return 3
        case "fitness_equipment": return 4
        case "swimming":          return 5
        case "walking":           return 6
        case "sedentary":
            return Int(profile.sedentaryActivityType)
        default:                  return 0
        }
    }
}
