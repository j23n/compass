import Foundation
import os
import CompassData

/// A minute-resolution sleep level sample from Garmin msg 274 (sleep_level).
/// One record per minute; this is the primary staging mechanism for Instinct Solar firmware.
public struct SleepLevelSample: Sendable {
    /// 0=unmeasurable, 1=awake, 2=light, 3=deep, 4=REM
    public let level: Int
    public let timestamp: Date

    public init(timestamp: Date, level: Int) {
        self.timestamp = timestamp
        self.level = level
    }
}

/// A lightweight sleep-parsing result (not tied to SwiftData).
public struct SleepResult: Sendable {
    public let startDate: Date
    public let endDate: Date
    public let score: Int?
    public let stages: [SleepStageResult]
    /// All minute-resolution level samples from msg 274 (empty if file uses msg 275 staging).
    public let rawLevelSamples: [SleepLevelSample]
    public let recoveryScore: Int?
    public let qualifier: String?

    public init(
        startDate: Date,
        endDate: Date,
        score: Int?,
        stages: [SleepStageResult],
        rawLevelSamples: [SleepLevelSample] = [],
        recoveryScore: Int? = nil,
        qualifier: String? = nil
    ) {
        self.startDate = startDate
        self.endDate = endDate
        self.score = score
        self.stages = stages
        self.rawLevelSamples = rawLevelSamples
        self.recoveryScore = recoveryScore
        self.qualifier = qualifier
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
/// Handles:
/// - sleep_data_info (273) for session-level data (score, start/end)
/// - sleep_level (274) for minute-by-minute staging (primary on Instinct Solar)
/// - sleep_stage (275) for stage entries (fallback if no 274 records)
/// - sleep_assessment (276) for overall quality — field dump pending field map
/// - sleep_restless_moments (382) for restless periods
public struct SleepFITParser: Sendable {

    private static let logger = Logger(subsystem: "com.compass.fit", category: "SleepFITParser")

    // Garmin-specific message numbers
    private static let sleepDataInfoMessageNum: UInt16 = 273
    private static let sleepStageMessageNum: UInt16 = 275
    private static let sleepLevelMessageNum: UInt16 = 274
    private static let sleepAssessmentMessageNum: UInt16 = 276
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

    // sleep_level (274) fields
    private static let sleepLevelField: UInt8 = 0

    /// Minimum session duration to be considered valid (10 minutes).
    private static let minimumDuration: TimeInterval = 600

    private let overlay: FieldNameOverlay

    public init(overlay: FieldNameOverlay = FieldNameOverlay()) {
        self.overlay = overlay
    }

    /// Parses a sleep FIT file and returns a ``SleepResult``, or `nil` if no valid sleep data was found.
    ///
    /// - Parameter data: Raw bytes of the FIT file.
    /// - Returns: A ``SleepResult`` with stages, or `nil` for empty/degenerate files.
    public func parse(data: Data) async throws -> SleepResult? {
        let decoder = FITDecoder()
        let fitFile = try decoder.decode(data: data)

        var sleepInfo: [UInt8: FITFieldValue]?
        var rawStages: [(timestamp: Date, stageValue: Int, durationSeconds: Int)] = []
        var levelSamples: [SleepLevelSample] = []

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

            case Self.sleepLevelMessageNum:
                if let sample = parseSleepLevel(from: message.fields) {
                    levelSamples.append(sample)
                }

            case Self.sleepAssessmentMessageNum:
                // Field dump — once field map is confirmed, replace with full decode
                for (fieldNum, value) in message.fields.sorted(by: { $0.key < $1.key }) {
                    Self.logger.debug("MSG276 field[\(fieldNum)] = \(String(describing: value))")
                }

            case Self.sleepRestlessMomentsMessageNum:
                Self.logger.debug("Sleep restless moment found")

            default:
                let enriched = overlay.apply(toMessage: message.globalMessageNumber, fields: message.fields)
                if enriched.messageName == nil {
                    Self.logger.debug("Unknown sleep message \(message.globalMessageNumber)")
                }
            }
        }

        guard sleepInfo != nil || !levelSamples.isEmpty else {
            Self.logger.warning("No usable sleep data found in FIT file (no msg 273 or 274 records)")
            return nil
        }

        return buildSleepResult(from: sleepInfo, rawStages: rawStages, levelSamples: levelSamples)
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

    private func parseSleepLevel(from fields: [UInt8: FITFieldValue]) -> SleepLevelSample? {
        guard let timestamp = fields[Self.fieldTimestamp].flatMap(FITTimestamp.date(from:)),
              let level = fields[Self.sleepLevelField]?.intValue else {
            return nil
        }
        return SleepLevelSample(timestamp: timestamp, level: level)
    }

    private func buildSleepResult(
        from info: [UInt8: FITFieldValue]?,
        rawStages: [(timestamp: Date, stageValue: Int, durationSeconds: Int)],
        levelSamples: [SleepLevelSample]
    ) -> SleepResult? {
        let score = info?[Self.sleepScore]?.intValue

        // Derive session bounds: prefer msg 273 explicit times, then msg 274 level samples,
        // then msg 275 stage timestamps as last resort.
        let startDate: Date
        let endDate: Date

        if let info = info,
           let start = info[Self.sleepStartTime].flatMap(FITTimestamp.date(from:)),
           let end = info[Self.sleepEndTime].flatMap(FITTimestamp.date(from:)),
           end > start {
            startDate = start
            endDate = end
        } else if !levelSamples.isEmpty {
            startDate = levelSamples.first!.timestamp
            // Each level record = 1 minute; add 60s to include the last minute
            endDate = levelSamples.last!.timestamp.addingTimeInterval(60)
        } else if !rawStages.isEmpty {
            startDate = rawStages.first!.timestamp
            let last = rawStages.last!
            endDate = last.timestamp.addingTimeInterval(TimeInterval(last.durationSeconds))
        } else {
            Self.logger.warning("Cannot determine session bounds — no level samples or stage records")
            return nil
        }

        // Filter degenerate sessions (unworn watch, Jan ghost entries, etc.)
        let duration = endDate.timeIntervalSince(startDate)
        guard duration >= Self.minimumDuration else {
            Self.logger.warning("Skipping degenerate sleep session (duration: \(Int(duration))s < \(Int(Self.minimumDuration))s)")
            return nil
        }

        // Prefer msg 274 minute-level samples for staging; fall back to msg 275 if absent.
        let stages: [SleepStageResult]
        if !levelSamples.isEmpty {
            stages = buildStagesFromLevelSamples(levelSamples)
        } else {
            stages = rawStages.compactMap { raw in
                guard let stageType = mapSleepStage(raw.stageValue) else { return nil }
                let stageEnd = raw.timestamp.addingTimeInterval(TimeInterval(raw.durationSeconds))
                return SleepStageResult(startDate: raw.timestamp, endDate: stageEnd, stage: stageType)
            }
        }

        return SleepResult(
            startDate: startDate,
            endDate: endDate,
            score: score,
            stages: stages,
            rawLevelSamples: levelSamples
        )
    }

    /// Collapses consecutive same-level msg 274 records into ``SleepStageResult`` spans.
    ///
    /// Level 0 (unmeasurable) is skipped. Each record represents 60 seconds.
    private func buildStagesFromLevelSamples(_ samples: [SleepLevelSample]) -> [SleepStageResult] {
        guard !samples.isEmpty else { return [] }

        var stages: [SleepStageResult] = []
        var groupStart = samples[0].timestamp
        var currentLevel = samples[0].level

        for i in 1..<samples.count {
            let sample = samples[i]
            if sample.level != currentLevel {
                if let stageType = mapLevelToStageType(currentLevel) {
                    let groupEnd = samples[i - 1].timestamp.addingTimeInterval(60)
                    stages.append(SleepStageResult(startDate: groupStart, endDate: groupEnd, stage: stageType))
                }
                groupStart = sample.timestamp
                currentLevel = sample.level
            }
        }

        // Flush the last group
        if let stageType = mapLevelToStageType(currentLevel) {
            let groupEnd = samples.last!.timestamp.addingTimeInterval(60)
            stages.append(SleepStageResult(startDate: groupStart, endDate: groupEnd, stage: stageType))
        }

        return stages
    }

    /// Maps msg 274 level values to `SleepStageType`.
    /// 0=unmeasurable (returns nil), 1=awake, 2=light, 3=deep, 4=REM
    private func mapLevelToStageType(_ level: Int) -> SleepStageType? {
        switch level {
        case 1: return .awake
        case 2: return .light
        case 3: return .deep
        case 4: return .rem
        default: return nil
        }
    }

    /// Maps Garmin msg 275 sleep stage enum values to `SleepStageType`.
    /// 0=deep, 1=light, 2=REM, 3=awake
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
