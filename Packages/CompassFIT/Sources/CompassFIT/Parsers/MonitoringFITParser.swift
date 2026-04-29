import Foundation
import os
import CompassData

/// Parses Garmin `/GARMIN/Monitor/*.fit` files and returns arrays of health samples.
///
/// Uses the field-name overlay to identify Garmin-proprietary messages:
/// - Monitoring messages (mesg_num 55) for step data
/// - monitoring_hr (140) for heart-rate samples
/// - body_battery (346) for Body Battery levels
/// - stress messages (mesg_num 227) for stress scores
/// - respiration messages (mesg_num 297) for breathing rate
public struct MonitoringFITParser: Sendable {

    private static let logger = Logger(subsystem: "com.compass.fit", category: "MonitoringFITParser")

    // Standard FIT message numbers
    private static let monitoringMessageNum: UInt16 = 55
    private static let stressMessageNum: UInt16 = 227
    private static let respirationMessageNum: UInt16 = 297

    // Garmin-specific message numbers (from overlay)
    private static let monitoringHRMessageNum: UInt16 = 140
    private static let bodyBatteryMessageNum: UInt16 = 346

    // Common field numbers
    private static let fieldTimestamp: UInt8 = 253

    // Monitoring (55) fields
    private static let monitoringCycles: UInt8 = 2    // steps = cycles * 2 for walking
    private static let monitoringActivityType: UInt8 = 5

    // monitoring_hr (140) fields
    private static let heartRateField: UInt8 = 1

    // body_battery (346) fields (from overlay)
    private static let bbLevel: UInt8 = 0
    private static let bbCharged: UInt8 = 1
    private static let bbDrained: UInt8 = 2

    // stress (227) fields
    private static let stressLevel: UInt8 = 0

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
        var stepCounts: [StepCount] = []
        var bodyBatterySamples: [BodyBatterySample] = []
        var respirationSamples: [RespirationSample] = []

        for message in fitFile.messages {
            switch message.globalMessageNumber {
            case Self.monitoringMessageNum:
                if let step = parseStepCount(from: message.fields) {
                    stepCounts.append(step)
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
            stepCounts: stepCounts,
            bodyBatterySamples: bodyBatterySamples,
            respirationSamples: respirationSamples
        )
    }

    // MARK: - Private parsing helpers

    private func parseStepCount(from fields: [UInt8: FITFieldValue]) -> StepCount? {
        guard let timestamp = fields[Self.fieldTimestamp].flatMap(FITTimestamp.date(from:)),
              let cycles = fields[Self.monitoringCycles]?.intValue else {
            return nil
        }
        // For walking/running, steps = cycles * 2. Activity type 6 = walking, 1 = running.
        let activityType = fields[Self.monitoringActivityType]?.intValue ?? 6
        let multiplier = (activityType == 1 || activityType == 6) ? 2 : 1
        let steps = cycles * multiplier
        return StepCount(timestamp: timestamp, steps: steps)
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
        guard let timestamp = fields[Self.fieldTimestamp].flatMap(FITTimestamp.date(from:)),
              let score = fields[Self.stressLevel]?.intValue,
              score >= 0, score <= 100 else {
            return nil
        }
        return StressSampleValue(timestamp: timestamp, stressScore: score)
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
