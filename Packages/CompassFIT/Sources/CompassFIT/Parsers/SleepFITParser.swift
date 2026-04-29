import Foundation
import os
import CompassData

/// A lightweight sleep-parsing result (not tied to SwiftData).
public struct SleepResult: Sendable {
    public let startDate: Date
    public let endDate: Date
    public let score: Int?
    public let stages: [SleepStageResult]

    public init(startDate: Date, endDate: Date, score: Int?, stages: [SleepStageResult]) {
        self.startDate = startDate
        self.endDate = endDate
        self.score = score
        self.stages = stages
    }
}

/// A lightweight sleep-stage result (not tied to SwiftData).
public struct SleepStageResult: Sendable {
    public let startDate: Date
    public let endDate: Date
    public let stage: SleepStageType

    public init(startDate: Date, endDate: Date, stage: SleepStageType) {
        self.startDate = startDate
        self.endDate = endDate
        self.stage = stage
    }
}

/// Parses Garmin `/GARMIN/Sleep/*.fit` files into sleep session data.
///
/// Uses the overlay to identify:
/// - sleep_data_info (273) for session-level data (score, start/end)
/// - sleep_stage (275) for individual stage entries
/// - sleep_restless_moments (382) for restless periods
public struct SleepFITParser: Sendable {

    private static let logger = Logger(subsystem: "com.compass.fit", category: "SleepFITParser")

    // Garmin-specific message numbers (from overlay)
    private static let sleepDataInfoMessageNum: UInt16 = 273
    private static let sleepStageMessageNum: UInt16 = 275
    private static let sleepRestlessMomentsMessageNum: UInt16 = 382

    // Common field numbers
    private static let fieldTimestamp: UInt8 = 253

    // sleep_data_info (273) fields
    private static let sleepScore: UInt8 = 0
    private static let sleepStartTime: UInt8 = 2
    private static let sleepEndTime: UInt8 = 3

    // sleep_stage (275) fields
    private static let stageType: UInt8 = 0
    private static let stageDuration: UInt8 = 1

    private let overlay: FieldNameOverlay

    public init(overlay: FieldNameOverlay = FieldNameOverlay()) {
        self.overlay = overlay
    }

    /// Parses a sleep FIT file and returns a ``SleepResult``, or `nil` if no sleep data was found.
    ///
    /// - Parameter data: Raw bytes of the FIT file.
    /// - Returns: A ``SleepResult`` with stages, or `nil`.
    public func parse(data: Data) async throws -> SleepResult? {
        let decoder = FITDecoder()
        let fitFile = try decoder.decode(data: data)

        var sleepInfo: [UInt8: FITFieldValue]?
        var rawStages: [(timestamp: Date, stageValue: Int, durationSeconds: Int)] = []

        for message in fitFile.messages {
            switch message.globalMessageNumber {
            case Self.sleepDataInfoMessageNum:
                if sleepInfo == nil {
                    sleepInfo = message.fields
                }

            case Self.sleepStageMessageNum:
                if let stage = parseSleepStage(from: message.fields) {
                    rawStages.append(stage)
                }

            case Self.sleepRestlessMomentsMessageNum:
                // Noted but not yet mapped.
                Self.logger.debug("Sleep restless moment found")

            default:
                let enriched = overlay.apply(toMessage: message.globalMessageNumber, fields: message.fields)
                if enriched.messageName == nil {
                    Self.logger.debug("Unknown sleep message \(message.globalMessageNumber)")
                }
            }
        }

        guard let info = sleepInfo else {
            Self.logger.warning("No sleep_data_info message found in sleep FIT file")
            return nil
        }

        return buildSleepResult(from: info, rawStages: rawStages)
    }

    // MARK: - Private helpers

    private func parseSleepStage(from fields: [UInt8: FITFieldValue]) -> (timestamp: Date, stageValue: Int, durationSeconds: Int)? {
        guard let timestamp = fields[Self.fieldTimestamp].flatMap(FITTimestamp.date(from:)),
              let stageValue = fields[Self.stageType]?.intValue,
              let duration = fields[Self.stageDuration]?.intValue else {
            return nil
        }
        return (timestamp: timestamp, stageValue: stageValue, durationSeconds: duration)
    }

    private func buildSleepResult(from info: [UInt8: FITFieldValue], rawStages: [(timestamp: Date, stageValue: Int, durationSeconds: Int)]) -> SleepResult {
        let score = info[Self.sleepScore]?.intValue
        let startDate = info[Self.sleepStartTime].flatMap(FITTimestamp.date(from:))
            ?? rawStages.first?.timestamp
            ?? Date()
        let endDate = info[Self.sleepEndTime].flatMap(FITTimestamp.date(from:))
            ?? rawStages.last.map { $0.timestamp.addingTimeInterval(TimeInterval($0.durationSeconds)) }
            ?? startDate

        let stages: [SleepStageResult] = rawStages.compactMap { raw in
            guard let stageType = mapSleepStage(raw.stageValue) else { return nil }
            let stageEnd = raw.timestamp.addingTimeInterval(TimeInterval(raw.durationSeconds))
            return SleepStageResult(
                startDate: raw.timestamp,
                endDate: stageEnd,
                stage: stageType
            )
        }

        return SleepResult(
            startDate: startDate,
            endDate: endDate,
            score: score,
            stages: stages
        )
    }

    /// Maps Garmin sleep stage enum values to CompassData `SleepStageType`.
    ///
    /// Garmin values (from observation / HarryOnline):
    /// 0 = deep, 1 = light, 2 = REM, 3 = awake
    private func mapSleepStage(_ value: Int) -> SleepStageType? {
        switch value {
        case 0: return .deep
        case 1: return .light
        case 2: return .rem
        case 3: return .awake
        default:
            Self.logger.warning("Unknown sleep stage value: \(value)")
            return nil
        }
    }
}
