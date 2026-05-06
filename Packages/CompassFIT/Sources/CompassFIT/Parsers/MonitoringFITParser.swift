import Foundation
import os
import FitFileParser
import CompassData

/// Parses Garmin `/GARMIN/Monitor/*.fit` files and returns arrays of health samples.
///
/// - Monitoring messages (55) — step/activity interval data; compact HR variant (fields 26/27)
/// - Monitoring HR data (211) — daily resting-heart-rate metric
/// - Stress (227) — stress score samples
/// - Respiration (297) — breathing rate samples
/// - SpO₂ (305 / 269) — blood oxygen saturation
/// - HSA (306/307/308/314) — hsa_stress, hsa_respiration, hsa_heart_rate, hsa_body_battery
/// - Monitoring_v2 (233) — field dump until field map is confirmed
public struct MonitoringFITParser: Sendable {

    private static let logger = Logger(subsystem: "com.compass.fit", category: "MonitoringFITParser")

    /// HR threshold for active / intensity minutes (beats per minute).
    /// Any minute that contains an HR sample ≥ this value counts as one intensity minute.
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
        var restingHeartRateSamples: [HeartRateSampleValue] = []
        var stressSamples: [StressSampleValue] = []
        var intervals: [MonitoringInterval] = []
        var bodyBatterySamples: [BodyBatterySample] = []
        var respirationSamples: [RespirationSample] = []
        var spo2Samples: [SpO2SampleValue] = []

        // Msg 55 `cycles` field is cumulative since midnight. Track per activity_type string.
        // Use Optional so the very first reading per type can be detected (snapshot, not delta).
        var lastCyclesByType: [String: Int] = [:]
        // Day-start → activity-type → max cumulative observed. Drives accurate daily step totals.
        var dailyMaxByType: [Date: [String: Int]] = [:]
        // Track last full Garmin-epoch timestamp seen (for timestamp_16 resolution).
        var lastFullTimestamp: UInt32 = 0

        for message in fitFile.messages {
            // Update running 32-bit timestamp from any message that carries one.
            if let date = FITTimestamp.resolve(message) {
                lastFullTimestamp = UInt32(max(0, date.timeIntervalSince(FITTimestamp.epoch)))
            }

            switch message.messageType {
            case .monitoring:
                if let hr = parseMonitoringHR(from: message, lastFullTimestamp: lastFullTimestamp) {
                    heartRateSamples.append(hr)
                }
                if let interval = parseMonitoringInterval(
                    from: message,
                    lastCycles: &lastCyclesByType,
                    dailyMaxByType: &dailyMaxByType
                ) {
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

            case .monitoring_hr_data:
                if let sample = parseRestingHeartRate(from: message) {
                    restingHeartRateSamples.append(sample)
                }

            default:
                break
            }
        }

        // Derive active-minute timestamps from HR samples: any minute that contains at least
        // one HR reading ≥ threshold counts as one intensity minute. This is independent of
        // monitoring-interval cadence (which is irregular), so the per-minute count is correct.
        var activeMinuteSet: Set<Date> = []
        for hr in heartRateSamples where hr.bpm >= Self.intensityHRThreshold {
            let bucket = Date(timeIntervalSinceReferenceDate:
                floor(hr.timestamp.timeIntervalSinceReferenceDate / 60) * 60)
            activeMinuteSet.insert(bucket)
        }
        let activeMinuteTimestamps = activeMinuteSet.sorted()

        // Sum the day's cumulative max across activity types.
        var dailyStepTotals: [Date: Int] = [:]
        for (day, byType) in dailyMaxByType {
            dailyStepTotals[day] = byType.values.reduce(0, +)
        }

        return MonitoringData(
            heartRateSamples: heartRateSamples,
            restingHeartRateSamples: restingHeartRateSamples,
            stressSamples: stressSamples,
            intervals: intervals,
            bodyBatterySamples: bodyBatterySamples,
            respirationSamples: respirationSamples,
            spo2Samples: spo2Samples,
            activeMinuteTimestamps: activeMinuteTimestamps,
            dailyStepTotals: dailyStepTotals
        )
    }

    // MARK: - Private helpers

    /// Multiplier applied to the cumulative value read from monitoring field 3
    /// (named `cycles` or `steps` depending on dynamic-rename). The factor is 2
    /// for both spellings of the field — *not* a strides-to-steps conversion, but
    /// a compensation for a field-ordering quirk inside the vendored FitFileParser:
    ///
    /// In Instinct Solar 1G monitoring_b summary records, the FIT field definition
    /// lists field 3 (cycles/steps) *before* field 5 (activity_type). The C
    /// interpreter (`FitInterpretMesg.m:251-252`) resolves a field's scale at the
    /// moment that field is processed; for field 3 it calls
    /// `fit_interp_string_value(interp, 5)` to look up activity_type and pick the
    /// per-activity scale. Because field 5 hasn't been seen yet, the call returns
    /// `FIT_UINT32_INVALID`, so the lookup falls through to the default `scale=2`
    /// branch even when activity_type is actually `walking` (which the FIT profile
    /// would otherwise map to `scale=1`). The interpreter then divides the raw
    /// uint32 by 2, halving the step count before Swift sees it.
    ///
    /// Streaming records (no activity_type field at all) intentionally use the
    /// `scale=2` default in the FIT profile, so the same multiplier applies there
    /// for the same numeric reason. Either way, multiplying by 2 here recovers the
    /// firmware's intended cumulative step count and matches the watch's display.
    private static let stridesToStepsFactor: Int = 2

    /// Returns the local day a monitoring record should be attributed to.
    ///
    /// The Instinct firmware closes a `monitoring_b` file at exactly local midnight
    /// and emits the day's final cumulative summary as the file's last record,
    /// timestamped at that midnight instant. Naive `startOfDay` bucketing pushes
    /// that summary into the *next* day, so day N's total leaks into day N+1.
    /// Treat a timestamp that lands exactly on `startOfDay(timestamp)` as the
    /// closing instant of the previous day instead.
    public static func dayBucket(for timestamp: Date) -> Date {
        let cal = Calendar.current
        let start = cal.startOfDay(for: timestamp)
        if timestamp == start, let prev = cal.date(byAdding: .day, value: -1, to: start) {
            return prev
        }
        return start
    }

    private func parseMonitoringInterval(
        from message: FitMessage,
        lastCycles: inout [String: Int],
        dailyMaxByType: inout [Date: [String: Int]]
    ) -> MonitoringInterval? {
        guard let timestamp = FITTimestamp.resolve(message) else { return nil }

        // The activity_type comes from one of two fields:
        //   - field 5 (`activity_type`): set in monitoring_b summary messages and a
        //     few day-boundary messages. Resolves to the readable name directly.
        //   - field 24 (`current_activity_type_intensity`): packed byte in streaming
        //     monitoring messages. Lower 5 bits = activity_type, upper 3 = intensity.
        // We accept any type — Garmin's "generic" CATI bucket still carries real
        // background step counts in the cycles field. Per-type tracking remains so
        // each type's cumulative resets are handled independently.
        let activityType = resolveActivityType(from: message)

        // Per-interval step delta. The cumulative-since-midnight count appears
        // in field 3, dynamically renamed to `steps` on summary records (where
        // `activity_type` is set explicitly) and `cycles` on streaming records
        // (where only CATI is set). Both spellings come back from FitFileParser
        // halved — see `stridesToStepsFactor` for the field-order bug that causes
        // this — so we multiply by 2 either way.
        //
        // The first reading we see in a file is a snapshot of work already done
        // before the file's window started — we can't attribute those steps to any
        // specific minute, so skip emitting a delta. The day's cumulative max still
        // feeds the daily total via `dailyMaxByType`, so the total isn't lost.
        let rawCumulative = doubleValue(message, key: "steps")
                        ?? doubleValue(message, key: "cycles")
        let steps: Int
        if let rawCumulative {
            let cumulative = Int(rawCumulative * Double(Self.stridesToStepsFactor))
            if let prev = lastCycles[activityType] {
                steps = cumulative >= prev ? cumulative - prev : cumulative
            } else {
                steps = 0  // first cumulative reading per type per file → snapshot, not a delta
            }
            lastCycles[activityType] = cumulative

            let day = Self.dayBucket(for: timestamp)
            let prevMax = dailyMaxByType[day, default: [:]][activityType] ?? 0
            dailyMaxByType[day, default: [:]][activityType] = max(prevMax, cumulative)
        } else {
            steps = 0
        }

        let fv = message.interpretedField(key: "active_calories")
        let activeCalories = fv?.value ?? fv?.valueUnit?.value ?? 0.0

        // Intensity minutes are derived from HR samples after the full pass — see
        // `activeMinuteTimestamps` in `parse(data:)`. The per-interval field stays at 0.
        return MonitoringInterval(
            timestamp: timestamp,
            steps: steps,
            activityType: activityTypeInt(activityType),
            intensityMinutes: 0,
            activeCalories: activeCalories
        )
    }

    /// Names matching the FIT activity_type enum used elsewhere in this parser.
    /// Index = activity_type ordinal. Position 7 is unused on Instinct Solar 1G
    /// (sedentary lives at 8 — see `docs/garmin/devices/instinct-solar-1g.md`).
    private static let activityTypeNames: [String] = [
        "generic", "running", "cycling", "transition",
        "fitness_equipment", "swimming", "walking", "activity_type_7", "sedentary"
    ]

    private func resolveActivityType(from message: FitMessage) -> String {
        if let name = message.interpretedField(key: "activity_type")?.name {
            return name
        }
        if let cati = doubleValue(message, key: "current_activity_type_intensity") {
            // CATI is a uint8 but the parser may surface it as signed (e.g. -120 for 0x88).
            // Mask back to the byte's bit pattern, then take the low 5 bits.
            let packed = Int(cati) & 0xFF
            let typeIndex = packed & 0x1F
            if typeIndex < Self.activityTypeNames.count {
                return Self.activityTypeNames[typeIndex]
            }
        }
        return "generic"
    }

    private func parseStress(from message: FitMessage) -> StressSampleValue? {
        let timestamp = message.interpretedField(key: "stress_level_time")?.time
                     ?? FITTimestamp.resolve(message)
        guard let timestamp,
              let scoreVal = doubleValue(message, key: "stress_level_value") else { return nil }
        let score = Int(scoreVal)
        guard score >= 0, score <= 100 else { return nil }
        return StressSampleValue(timestamp: timestamp, stressScore: score)
    }

    /// Extracts an HR sample from the compact HR variant of monitoring msg 55.
    private func parseMonitoringHR(
        from message: FitMessage,
        lastFullTimestamp: UInt32
    ) -> HeartRateSampleValue? {
        guard let hrVal = doubleValue(message, key: "heart_rate"),
              hrVal > 0, hrVal != 255 else { return nil }
        let hr = Int(hrVal)

        if let date = FITTimestamp.resolve(message) {
            return HeartRateSampleValue(timestamp: date, bpm: hr)
        }
        if let ts16Raw = doubleValue(message, key: "timestamp_16") {
            let ts16 = UInt16(ts16Raw) & 0xFFFF
            let resolved = resolveTimestamp16(ts16, lastFull: lastFullTimestamp)
            return HeartRateSampleValue(timestamp: FITTimestamp.date(fromFITTimestamp: resolved), bpm: hr)
        }
        return nil
    }

    /// Extracts the daily resting heart rate from monitoring_hr_data (msg 211).
    /// The watch emits this once per minute with the running daily figure.
    private func parseRestingHeartRate(from message: FitMessage) -> HeartRateSampleValue? {
        guard let timestamp = FITTimestamp.resolve(message) else { return nil }
        let bpm = doubleValue(message, key: "current_day_resting_heart_rate")
              ?? doubleValue(message, key: "resting_heart_rate")
        guard let bpm, bpm > 0, bpm != 255 else { return nil }
        return HeartRateSampleValue(timestamp: timestamp, bpm: Int(bpm))
    }

    private func doubleValue(_ message: FitMessage, key: String) -> Double? {
        let fv = message.interpretedField(key: key)
        return fv?.value ?? fv?.valueUnit?.value
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
        guard let timestamp = FITTimestamp.resolve(message) else { return [] }
        return parsePipeArray(from: message, key: "heart_rate").enumerated().compactMap { i, hr in
            guard hr > 0, hr != 255 else { return nil }
            return HeartRateSampleValue(timestamp: timestamp.addingTimeInterval(TimeInterval(i)), bpm: Int(hr))
        }
    }

    private func parseHSAStress(from message: FitMessage, into samples: inout [StressSampleValue]) {
        guard let timestamp = FITTimestamp.resolve(message) else { return }
        for (i, stress) in parsePipeArray(from: message, key: "stress_level").enumerated() {
            guard stress >= 0 else { continue }
            samples.append(StressSampleValue(
                timestamp: timestamp.addingTimeInterval(TimeInterval(i)),
                stressScore: Int(stress)
            ))
        }
    }

    private func parseHSARespiration(from message: FitMessage, into samples: inout [RespirationSample]) {
        guard let timestamp = FITTimestamp.resolve(message) else { return }
        for (i, rate) in parsePipeArray(from: message, key: "respiration_rate").enumerated() {
            guard rate > 0, rate != 255 else { continue }
            samples.append(RespirationSample(
                timestamp: timestamp.addingTimeInterval(TimeInterval(i)),
                breathsPerMinute: rate
            ))
        }
    }

    private func parseHSABodyBattery(from message: FitMessage, into samples: inout [BodyBatterySample]) {
        guard let timestamp = FITTimestamp.resolve(message) else { return }
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
        guard let timestamp = FITTimestamp.resolve(message) else { return }
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
        guard let timestamp = FITTimestamp.resolve(message) else { return nil }
        guard let val = doubleValue(message, key: "reading_spo2") else { return nil }
        let pct = Int(val)
        guard pct >= 1, pct <= 100 else { return nil }
        return SpO2SampleValue(timestamp: timestamp, percent: pct)
    }

    private func parseRespiration(from message: FitMessage) -> RespirationSample? {
        guard let timestamp = FITTimestamp.resolve(message) else { return nil }
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
