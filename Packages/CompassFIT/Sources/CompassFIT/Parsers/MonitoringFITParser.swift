import Foundation
import os
import CompassData

/// Parses Garmin `/GARMIN/Monitor/*.fit` files and returns arrays of health samples.
///
/// Uses the field-name overlay to identify Garmin-proprietary messages:
/// - Monitoring messages (mesg_num 55) for step/activity interval data
/// - monitoring_hr (140) for heart-rate samples
/// - body_battery (346) for Body Battery levels
/// - stress messages (mesg_num 227) for stress scores
/// - respiration messages (mesg_num 297) for breathing rate
/// - monitoring_v2 (233) — field dump only until field map is confirmed from live data
public struct MonitoringFITParser: Sendable {

    private static let logger = Logger(subsystem: "com.compass.fit", category: "MonitoringFITParser")

    // Standard FIT message numbers
    private static let monitoringMessageNum: UInt16 = 55
    private static let stressMessageNum: UInt16 = 227
    private static let respirationMessageNum: UInt16 = 297

    // Garmin-specific message numbers (from overlay)
    private static let monitoringHRMessageNum: UInt16 = 140
    private static let bodyBatteryMessageNum: UInt16 = 346
    private static let monitoringV2MessageNum: UInt16 = 233   // field dump; full decode pending
    private static let healthSnapshotMessageNum: UInt16 = 318 // field dump; full decode pending

    // HSA (Health Snapshot Archive) message numbers — from Garmin FIT Python SDK profile.py
    private static let hsaHeartRateMessageNum: UInt16 = 308   // hsa_heart_rate_data
    private static let hsaStressMessageNum: UInt16 = 306      // hsa_stress_data
    private static let hsaRespirationMessageNum: UInt16 = 307 // hsa_respiration_data
    private static let hsaBodyBatteryMessageNum: UInt16 = 314 // hsa_body_battery_data

    // HSA field numbers (same across all HSA messages)
    // field 0: processing_interval (uint16, seconds) — length of the array fields
    // field 1+: data arrays (one element per second of the interval)
    private static let hsaProcessingInterval: UInt8 = 0

    // Common field numbers
    private static let fieldTimestamp: UInt8 = 253

    // Monitoring (55) fields
    // Field 2: `cycles` (generic) — always 0 on Instinct Solar fw 19.1; not used for steps
    private static let monitoringCycles: UInt8 = 2
    // Field 3: subfield — `steps` (uint32, raw count) when activity_type=walking/running,
    //           `active_time` (uint32, scale 1000, seconds) otherwise.
    //           On this firmware, steps are the raw step count (no ×2 needed).
    private static let monitoringStepsOrActiveTime: UInt8 = 3
    private static let monitoringActiveCalories: UInt8 = 4
    private static let monitoringActivityType: UInt8 = 5
    // Compact HR variant in msg 55 (Instinct 2 Solar Surf firmware):
    // field 26 = timestamp_16 (uint16, lower 16 bits of Garmin epoch ts)
    // field 27 = heart_rate (uint8, bpm)
    private static let monitoringTimestamp16: UInt8 = 26
    private static let monitoringHRInMsg55: UInt8 = 27

    // monitoring_hr (140) fields
    private static let heartRateField: UInt8 = 1

    // body_battery (346) fields (from overlay)
    private static let bbLevel: UInt8 = 0
    private static let bbCharged: UInt8 = 1
    private static let bbDrained: UInt8 = 2

    // stress (227) fields
    // NOTE: msg 227 uses field 1 (stress_level_time) as timestamp — NOT field 253.
    private static let stressLevel: UInt8 = 0
    private static let stressTimestampField: UInt8 = 1    // uint32, Garmin epoch

    // respiration (297) fields
    private static let respirationRate: UInt8 = 0

    private let overlay: FieldNameOverlay

    public init(overlay: FieldNameOverlay = FieldNameOverlay()) {
        self.overlay = overlay
    }

    /// Parses a monitoring FIT file and returns aggregated health data.
    ///
    /// - Parameter data: Raw bytes of the FIT file.
    /// - Returns: A ``MonitoringData`` value with all extracted samples.
    public func parse(data: Data) async throws -> MonitoringData {
        let decoder = FITDecoder()
        let fitFile = try decoder.decode(data: data)

        var heartRateSamples: [HeartRateSampleValue] = []
        var stressSamples: [StressSampleValue] = []
        var intervals: [MonitoringInterval] = []
        var bodyBatterySamples: [BodyBatterySample] = []
        var respirationSamples: [RespirationSample] = []

        // Msg 55 `cycles` field is cumulative since midnight (FIT SDK spec).
        // Track the last value per activity_type to compute per-interval deltas.
        var lastCyclesByType: [Int: Int] = [:]
        // Track last full Garmin-epoch timestamp seen (for timestamp_16 resolution).
        var lastFullTimestamp: UInt32 = 0

        for message in fitFile.messages {
            // Update running timestamp from any explicit field 253.
            if let tsVal = message.fields[Self.fieldTimestamp]?.uint32Value {
                lastFullTimestamp = tsVal
            }

            switch message.globalMessageNumber {
            case Self.monitoringMessageNum:
                // Compact HR variant embeds heart_rate (field 27) in the monitoring message.
                if let hr = parseMonitoringHR(from: message.fields, lastFullTimestamp: lastFullTimestamp) {
                    heartRateSamples.append(hr)
                }
                if let interval = parseMonitoringInterval(from: message.fields, lastCycles: &lastCyclesByType) {
                    intervals.append(interval)
                }

            case Self.monitoringHRMessageNum:
                if let hr = parseHeartRate(from: message.fields) {
                    heartRateSamples.append(hr)
                }

            case Self.bodyBatteryMessageNum:
                if let bb = parseBodyBattery(from: message.fields) {
                    bodyBatterySamples.append(bb)
                }

            case Self.stressMessageNum:
                if let stress = parseStress(from: message.fields) {
                    stressSamples.append(stress)
                }

            case Self.respirationMessageNum:
                if let resp = parseRespiration(from: message.fields) {
                    respirationSamples.append(resp)
                }

            // HSA messages — official Garmin FIT Python SDK profile.py
            case Self.hsaHeartRateMessageNum:
                parseHSAHeartRate(from: message.fields, into: &heartRateSamples)

            case Self.hsaStressMessageNum:
                parseHSAStress(from: message.fields, into: &stressSamples)

            case Self.hsaRespirationMessageNum:
                parseHSARespiration(from: message.fields, into: &respirationSamples)

            case Self.hsaBodyBatteryMessageNum:
                parseHSABodyBattery(from: message.fields, into: &bodyBatterySamples)

            case Self.monitoringV2MessageNum:
                // Field dump — once field map is confirmed from a live sync, replace with full decode.
                // Timestamps come from compressed-timestamp injection (field 253, Garmin epoch uint32).
                for (fieldNum, value) in message.fields.sorted(by: { $0.key < $1.key }) {
                    if case .data(let bytes) = value {
                        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
                        Self.logger.info("MSG233 field[\(fieldNum)] = data(\(bytes.count)B) hex=[\(hex)]")
                    } else {
                        Self.logger.info("MSG233 field[\(fieldNum)] = \(String(describing: value))")
                    }
                }

            case Self.healthSnapshotMessageNum:
                // Field dump — full decode pending field map confirmation.
                for (fieldNum, value) in message.fields.sorted(by: { $0.key < $1.key }) {
                    if case .data(let bytes) = value {
                        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
                        Self.logger.info("MSG318 field[\(fieldNum)] = data(\(bytes.count)B) hex=[\(hex)]")
                    } else {
                        Self.logger.info("MSG318 field[\(fieldNum)] = \(String(describing: value))")
                    }
                }

            default:
                let enriched = overlay.apply(toMessage: message.globalMessageNumber, fields: message.fields)
                if enriched.messageName == nil {
                    Self.logger.debug("Unknown monitoring message \(message.globalMessageNumber)")
                }
            }
        }

        return MonitoringData(
            heartRateSamples: heartRateSamples,
            stressSamples: stressSamples,
            intervals: intervals,
            bodyBatterySamples: bodyBatterySamples,
            respirationSamples: respirationSamples
        )
    }

    // MARK: - Private parsing helpers

    // FIT activity_type enum (msg 55, field 5) as observed on Instinct Solar (1st gen) fw 19.1:
    //   0=generic, 1=running, 2=cycling, 3=transition, 4=fitness_equipment,
    //   5=swimming, 6=walking, 8=sedentary (NOT 7 — confirmed from USB dump), 254=invalid
    // The `intensity` field (field 28) is packed into the high 5 bits of
    // `current_activity_type_intensity` (field 29); activity_type in the low 3 bits.
    private static let sedentaryActivityType: Int = 8

    private func parseMonitoringInterval(
        from fields: [UInt8: FITFieldValue],
        lastCycles: inout [Int: Int]
    ) -> MonitoringInterval? {
        guard let timestamp = fields[Self.fieldTimestamp].flatMap(FITTimestamp.date(from:)) else {
            return nil
        }
        let activityType = fields[Self.monitoringActivityType]?.intValue ?? 0

        // Field 3 is a FIT subfield:
        //   - activity_type = walking (6) or running (1): raw value = cumulative step count
        //   - otherwise: raw value = active_time in ms (scale 1000)
        // Field 2 (cycles) is always 0 on Instinct Solar fw 19.1; ignore it.
        let isStepActivity = (activityType == 1 || activityType == 6)
        let field3 = fields[Self.monitoringStepsOrActiveTime]?.intValue ?? 0

        let steps: Int
        if isStepActivity {
            // field 3 = cumulative steps since midnight; compute delta.
            let prev = lastCycles[activityType] ?? 0
            let delta = field3 >= prev ? field3 - prev : field3  // rollover at midnight
            lastCycles[activityType] = field3
            steps = delta
        } else {
            steps = 0
        }

        // Sedentary = raw 8 on Instinct Solar fw 19.1 (confirmed from USB FIT dump).
        let intensityMinutes = (activityType == Self.sedentaryActivityType) ? 0 : 1

        let activeCalories = fields[Self.monitoringActiveCalories]?.doubleValue ?? 0.0
        return MonitoringInterval(
            timestamp: timestamp,
            steps: steps,
            activityType: activityType,
            intensityMinutes: intensityMinutes,
            activeCalories: activeCalories
        )
    }

    private func parseHeartRate(from fields: [UInt8: FITFieldValue]) -> HeartRateSampleValue? {
        guard let timestamp = fields[Self.fieldTimestamp].flatMap(FITTimestamp.date(from:)),
              let bpm = fields[Self.heartRateField]?.intValue,
              bpm > 0 else {
            return nil
        }
        return HeartRateSampleValue(timestamp: timestamp, bpm: bpm)
    }

    private func parseBodyBattery(from fields: [UInt8: FITFieldValue]) -> BodyBatterySample? {
        guard let timestamp = fields[Self.fieldTimestamp].flatMap(FITTimestamp.date(from:)),
              let level = fields[Self.bbLevel]?.intValue else {
            return nil
        }
        let charged = fields[Self.bbCharged]?.intValue ?? 0
        let drained = fields[Self.bbDrained]?.intValue ?? 0
        return BodyBatterySample(timestamp: timestamp, level: level, charged: charged, drained: drained)
    }

    private func parseStress(from fields: [UInt8: FITFieldValue]) -> StressSampleValue? {
        // msg 227 uses field 1 (stress_level_time, uint32) as the timestamp, not field 253.
        // Fall back to field 253 for any future firmware that uses the standard layout.
        let timestamp = fields[Self.stressTimestampField].flatMap(FITTimestamp.date(from:))
                     ?? fields[Self.fieldTimestamp].flatMap(FITTimestamp.date(from:))
        guard let timestamp,
              let score = fields[Self.stressLevel]?.intValue,
              score >= 0, score <= 100 else {
            return nil
        }
        return StressSampleValue(timestamp: timestamp, stressScore: score)
    }

    /// Extracts a heart-rate sample from the compact HR variant of monitoring msg 55.
    ///
    /// Compact variant: field 27 = heart_rate (uint8), field 26 = timestamp_16 (uint16).
    /// `timestamp_16` is the lower 16 bits of the full Garmin-epoch timestamp; the upper
    /// bits are inherited from `lastFullTimestamp`, with rollover detection.
    private func parseMonitoringHR(
        from fields: [UInt8: FITFieldValue],
        lastFullTimestamp: UInt32
    ) -> HeartRateSampleValue? {
        guard let hr = fields[Self.monitoringHRInMsg55]?.intValue,
              hr > 0, hr != 255 else { return nil }

        // Prefer explicit field 253; fall back to timestamp_16 (field 26).
        let date: Date?
        if let explicit = fields[Self.fieldTimestamp].flatMap(FITTimestamp.date(from:)) {
            date = explicit
        } else if let ts16Raw = fields[Self.monitoringTimestamp16]?.uint32Value {
            let ts16 = UInt16(ts16Raw & 0xFFFF)
            let resolved = resolveTimestamp16(ts16, lastFull: lastFullTimestamp)
            date = FITTimestamp.date(from: .uint32(resolved))
        } else {
            date = nil
        }
        guard let timestamp = date else { return nil }
        return HeartRateSampleValue(timestamp: timestamp, bpm: hr)
    }

    /// Resolves a 16-bit timestamp offset against the last known full 32-bit Garmin timestamp.
    private func resolveTimestamp16(_ ts16: UInt16, lastFull: UInt32) -> UInt32 {
        let lastLow = lastFull & 0xFFFF
        var full = (lastFull & 0xFFFF0000) | UInt32(ts16)
        if UInt32(ts16) < lastLow {
            full = full &+ 0x10000
        }
        return full
    }

    // MARK: - HSA (Health Snapshot Archive) parsing helpers
    //
    // HSA messages carry a `processing_interval` (field 0, uint16, seconds) and
    // one or more array fields where each element covers one second of data.
    // The message timestamp marks the *start* of the interval; element [i] is at
    // timestamp + i seconds.
    //
    // Source: Garmin FIT Python SDK profile.py

    /// hsa_heart_rate_data (308)
    /// field 1: status uint8 (0=searching, 1=locked)
    /// field 2: heart_rate uint8[], bpm — blank=0, invalid=255
    private func parseHSAHeartRate(from fields: [UInt8: FITFieldValue], into samples: inout [HeartRateSampleValue]) {
        guard let timestamp = fields[Self.fieldTimestamp].flatMap(FITTimestamp.date(from:)),
              let hrBytes = fields[2]?.uint8Array else { return }
        for (i, hr) in hrBytes.enumerated() {
            guard hr > 0, hr != 255 else { continue }
            samples.append(HeartRateSampleValue(
                timestamp: timestamp.addingTimeInterval(TimeInterval(i)),
                bpm: Int(hr)
            ))
        }
    }

    /// hsa_stress_data (306)
    /// field 1: stress_level sint8[] — 0-100 valid; negative = not measured
    ///   -1=off_wrist, -2=excess_motion, -3=insufficient_data,
    ///   -4=recovering_from_exercise, -5=unidentified, -16=blank
    private func parseHSAStress(from fields: [UInt8: FITFieldValue], into samples: inout [StressSampleValue]) {
        guard let timestamp = fields[Self.fieldTimestamp].flatMap(FITTimestamp.date(from:)),
              let stressBytes = fields[1]?.int8Array else { return }
        for (i, stress) in stressBytes.enumerated() {
            guard stress >= 0 else { continue }
            samples.append(StressSampleValue(
                timestamp: timestamp.addingTimeInterval(TimeInterval(i)),
                stressScore: Int(stress)
            ))
        }
    }

    /// hsa_respiration_data (307)
    /// field 1: respiration_rate uint8[] breaths/min — 0=blank, 255=invalid
    private func parseHSARespiration(from fields: [UInt8: FITFieldValue], into samples: inout [RespirationSample]) {
        guard let timestamp = fields[Self.fieldTimestamp].flatMap(FITTimestamp.date(from:)),
              let rateBytes = fields[1]?.uint8Array else { return }
        for (i, rate) in rateBytes.enumerated() {
            guard rate > 0, rate != 255 else { continue }
            samples.append(RespirationSample(
                timestamp: timestamp.addingTimeInterval(TimeInterval(i)),
                breathsPerMinute: Double(rate)
            ))
        }
    }

    /// hsa_body_battery_data (314)
    /// field 1: level sint8[] — 0-100 valid; -16=blank
    /// field 2: charged sint16[] (delta)
    /// field 3: uncharged sint16[] (delta)
    private func parseHSABodyBattery(from fields: [UInt8: FITFieldValue], into samples: inout [BodyBatterySample]) {
        guard let timestamp = fields[Self.fieldTimestamp].flatMap(FITTimestamp.date(from:)),
              let levelBytes = fields[1]?.int8Array else { return }
        for (i, level) in levelBytes.enumerated() {
            guard level >= 0 else { continue }  // -16 = blank, other negatives = error
            samples.append(BodyBatterySample(
                timestamp: timestamp.addingTimeInterval(TimeInterval(i)),
                level: Int(level),
                charged: 0,
                drained: 0
            ))
        }
    }

    private func parseRespiration(from fields: [UInt8: FITFieldValue]) -> RespirationSample? {
        guard let timestamp = fields[Self.fieldTimestamp].flatMap(FITTimestamp.date(from:)),
              let rate = fields[Self.respirationRate]?.doubleValue,
              rate > 0 else {
            return nil
        }
        return RespirationSample(timestamp: timestamp, breathsPerMinute: rate)
    }
}
