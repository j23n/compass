import Foundation
import os
import FitFileParser
import CompassData

/// A lightweight sleep-parsing result (not tied to SwiftData).
public struct SleepResult: Sendable {
    public let startDate: Date
    public let endDate: Date
    /// Overall sleep score 0–100 from sleep_assessment (346) `overall_sleep_score`, or nil if absent.
    public let score: Int?
    public let stages: [SleepStageResult]
    public let recoveryScore: Int?
    public let qualifier: String?

    public init(
        startDate: Date,
        endDate: Date,
        score: Int?,
        stages: [SleepStageResult],
        recoveryScore: Int? = nil,
        qualifier: String? = nil
    ) {
        self.startDate = startDate
        self.endDate = endDate
        self.score = score
        self.stages = stages
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
/// Messages dispatched (FitFileParser names):
/// - sleep_data_info (273): session start (UTC `timestamp`)
/// - sleep_level (275): per-sample stage records (`sleep_level` enum: awake/light/deep/rem)
/// - sleep_data_raw (274): opaque sensor blobs — skipped
/// - sleep_session_end (276, no SDK constant): session end timestamp
/// - sleep_assessment (346): `overall_sleep_score` (0–100)
public struct SleepFITParser: Sendable {

    private static let logger = Logger(subsystem: "com.compass.fit", category: "SleepFITParser")

    /// Msg 276 has no named constant in the FIT SDK; live data shows field 253 = session end.
    private static let sleepSessionEnd: FitMessageType = 276

    /// Minimum session duration to be considered valid (10 minutes).
    private static let minimumDuration: TimeInterval = 600

    public init() {}

    public func parse(data: Data) async throws -> SleepResult? {
        let fitFile = FitFile(data: data, parsingType: .generic)

        var sessionStart: Date?
        var sessionEnd: Date?
        var overallScore: Int?
        var rawStages: [(timestamp: Date, stage: SleepStageType)] = []

        for message in fitFile.messages {
            switch message.messageType {
            case .sleep_data_info:
                if sessionStart == nil,
                   let ts = message.interpretedField(key: "timestamp")?.time {
                    sessionStart = ts
                }

            case .sleep_level:
                if let stage = parseSleepStage(from: message) {
                    rawStages.append(stage)
                }

            case .sleep_data_raw:
                break  // 20-byte opaque sensor blob

            case Self.sleepSessionEnd:
                if let ts = message.interpretedField(key: "timestamp")?.time {
                    sessionEnd = ts
                }

            case .sleep_assessment:
                if let v = message.interpretedField(key: "overall_sleep_score")?.value, v > 0 {
                    overallScore = Int(v)
                }

            case .sleep_restless_moments:
                Self.logger.debug("Sleep restless moment record")

            default:
                break
            }
        }

        guard sessionStart != nil || !rawStages.isEmpty else {
            Self.logger.warning("No usable sleep data (no msg 273 or 275)")
            return nil
        }

        return buildSleepResult(
            sessionStart: sessionStart,
            sessionEnd: sessionEnd,
            rawStages: rawStages,
            score: overallScore
        )
    }

    // MARK: - Private helpers

    private func parseSleepStage(from message: FitMessage) -> (timestamp: Date, stage: SleepStageType)? {
        guard let timestamp = message.interpretedField(key: "timestamp")?.time,
              let name = message.interpretedField(key: "sleep_level")?.name,
              let stage = mapSleepStageString(name) else {
            return nil
        }
        return (timestamp, stage)
    }

    private func mapSleepStageString(_ name: String) -> SleepStageType? {
        switch name {
        case "awake": return .awake
        case "light": return .light
        case "deep":  return .deep
        case "rem":   return .rem
        case "unmeasurable": return nil
        default:
            Self.logger.warning("Unknown sleep_level value: \(name)")
            return nil
        }
    }

    private func buildSleepResult(
        sessionStart: Date?,
        sessionEnd: Date?,
        rawStages: [(timestamp: Date, stage: SleepStageType)],
        score: Int?
    ) -> SleepResult? {
        let sortedStages = rawStages.sorted { $0.timestamp < $1.timestamp }

        let startDate: Date
        let endDate: Date

        if let start = sessionStart {
            startDate = start
            if let end = sessionEnd, end > start {
                endDate = end
            } else if let last = sortedStages.last {
                endDate = last.timestamp.addingTimeInterval(60)
            } else {
                Self.logger.warning("Cannot determine session end (no msg 276 and no stage records)")
                return nil
            }
        } else if let first = sortedStages.first {
            startDate = first.timestamp
            endDate = sessionEnd ?? sortedStages.last!.timestamp.addingTimeInterval(60)
        } else {
            return nil
        }

        let duration = endDate.timeIntervalSince(startDate)
        guard duration >= Self.minimumDuration else {
            Self.logger.warning("Skipping degenerate sleep session (duration: \(Int(duration))s)")
            return nil
        }

        let stages: [SleepStageResult] = sortedStages.enumerated().map { i, raw in
            let stageEnd = i + 1 < sortedStages.count
                ? sortedStages[i + 1].timestamp
                : endDate
            return SleepStageResult(startDate: raw.timestamp, endDate: stageEnd, stage: raw.stage)
        }

        return SleepResult(
            startDate: startDate,
            endDate: endDate,
            score: score,
            stages: stages
        )
    }
}
