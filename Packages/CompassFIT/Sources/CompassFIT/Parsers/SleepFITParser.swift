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
/// - sleep_data_raw (274): per-minute records — either standard uint8 level or
///   Instinct Solar 1G 20-byte opaque blob
/// - sleep_level (275): per-sample stage records (`sleep_level` enum: awake/light/deep/rem)
/// - sleep_session_end (276, no SDK constant): session end timestamp
/// - sleep_assessment (346): `overall_sleep_score` (0–100)
public struct SleepFITParser: Sendable {

    private static let logger = Logger(subsystem: "com.compass.fit", category: "SleepFITParser")

    /// Msg 276 has no named constant in the FIT SDK; live data shows field 253 = session end.
    private static let sleepSessionEnd: FitMessageType = 276

    /// Minimum session duration to be considered valid (10 minutes).
    private static let minimumDuration: TimeInterval = 600

    private let profile: DeviceProfile

    public init(profile: DeviceProfile = .default) {
        self.profile = profile
    }

    public func parse(data: Data) async throws -> SleepResult? {
        let fitFile = FitFile(data: data, parsingType: .generic)

        var sessionStart: Date?
        var sessionEnd: Date?
        var overallScore: Int?
        var recoveryScore: Int?
        var qualifier: String?
        var assessmentTimestamp: Date?
        var rawStages: [(timestamp: Date, stage: SleepStageType)] = []

        for message in fitFile.messages {
            switch message.messageType {
            case .sleep_data_info:
                if sessionStart == nil,
                   let ts = message.interpretedField(key: "timestamp")?.time {
                    sessionStart = ts
                }

            case .sleep_data_raw:
                // Skip — handled by profile-specific decoding below, OR
                // in standard mode this is opaque and we only use msg 275.
                break

            case .sleep_level:
                if let stage = parseSleepStage(from: message) {
                    rawStages.append(stage)
                }

            case Self.sleepSessionEnd:
                if let ts = message.interpretedField(key: "timestamp")?.time {
                    sessionEnd = ts
                }

            case .sleep_assessment:
                assessmentTimestamp = message.interpretedField(key: "timestamp")?.time
                if let v = message.interpretedField(key: "overall_sleep_score")?.value, v > 0 {
                    overallScore = Int(v)
                }
                if let v = message.interpretedField(key: "recovery_score")?.value {
                    recoveryScore = Int(v)
                }
                if let q = message.interpretedField(key: "sleep_qualifier")?.name {
                    qualifier = q
                }

            case .sleep_restless_moments:
                Self.logger.debug("Sleep restless moment record")

            default:
                break
            }
        }

        // Profile-specific msg 274 decoding
        switch profile.sleepMsg274Format {
        case .instinct20ByteBlob:
            let blobStages = decodeInstinctMsg274Blobs(from: data, sessionStart: sessionStart)
            if !blobStages.isEmpty {
                // Prefer blob-derived stages (higher resolution) over msg 275
                rawStages = blobStages
                Self.logger.info("Decoded \(blobStages.count) sleep stages from msg 274 20-byte blobs")
            }

        case .standard:
            // Try interpreting msg 274 (sleep_data_raw) fields — some devices
            // encode the level directly as field 0 with a proper timestamp.
            let rawStagesFrom274 = decodeStandardMsg274(from: fitFile)
            if !rawStagesFrom274.isEmpty {
                rawStages = rawStagesFrom274
                Self.logger.info("Decoded \(rawStagesFrom274.count) sleep stages from standard msg 274")
            }
        }

        // Assessment-only file: no session or stage records, but we have a score.
        // Return a minimal result so the file gets archived and the score is persisted.
        if sessionStart == nil && rawStages.isEmpty {
            if let ts = assessmentTimestamp, overallScore != nil {
                Self.logger.info("Assessment-only sleep file: score=\(overallScore!)")
                return SleepResult(startDate: ts, endDate: ts, score: overallScore, stages: [], recoveryScore: recoveryScore, qualifier: qualifier)
            }
            Self.logger.warning("No usable sleep data (no msg 273, 275, or assessment score)")
            return nil
        }

        return buildSleepResult(
            sessionStart: sessionStart,
            sessionEnd: sessionEnd,
            rawStages: rawStages,
            score: overallScore,
            recoveryScore: recoveryScore,
            qualifier: qualifier
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

    /// Decodes Instinct Solar 1G 20-byte msg 274 blobs using a raw FIT scan.
    ///
    /// Byte layout per the device doc:
    ///   [0-15]  8 × int16 LE — accelerometer statistics
    ///   [16-17] uint16 LE — motion metric (0 = still, >0 = movement)
    ///   [18]    uint8 — ancillary metric
    ///   [19]    uint8 — sleep stage: 81=deep, 82=light, 83=REM, 84-85=awake
    ///
    /// Timestamps are derived from record index × 60s from session start,
    /// since these records arrive at ~1/min cadence with no embedded timestamp.
    private func decodeInstinctMsg274Blobs(from data: Data, sessionStart: Date?) -> [(timestamp: Date, stage: SleepStageType)] {
        let scanner = RawFITRecordScanner()
        let rawRecords = scanner.scanRecords(data: data, targetMesgNum: 274)

        guard !rawRecords.isEmpty else { return [] }

        let records = rawRecords.filter { $0.count >= 20 }

        guard let start = sessionStart else {
            Self.logger.warning("Cannot decode Instinct msg 274 blobs — no session start from msg 273")
            return []
        }

        var results: [(timestamp: Date, stage: SleepStageType)] = []

        for (i, record) in records.enumerated() {
            let byte19 = record[19]
            let stage: SleepStageType
            switch byte19 {
            case 81: stage = .deep
            case 82: stage = .light
            case 83: stage = .rem
            case 84, 85: stage = .awake
            default:
                Self.logger.debug("Skipping Instinct msg 274 record \(i): unknown stage byte \(byte19)")
                continue
            }
            let ts = start.addingTimeInterval(TimeInterval(i * 60))
            results.append((timestamp: ts, stage: stage))
        }

        return results
    }

    /// Decodes standard msg 274 (`sleep_data_raw`) records where field 0 is
    /// the sleep level (uint8) and field 253 is the timestamp.
    ///
    /// Some devices encode per-minute staging in msg 274 rather than msg 275.
    private func decodeStandardMsg274(from fitFile: FitFile) -> [(timestamp: Date, stage: SleepStageType)] {
        var results: [(timestamp: Date, stage: SleepStageType)] = []

        for message in fitFile.messages where message.messageType == .sleep_data_raw {
            let name = message.interpretedField(key: "sleep_level")?.name
            let ts = message.interpretedField(key: "timestamp")?.time

            if let name, let stage = mapSleepStageString(name), let ts {
                results.append((timestamp: ts, stage: stage))
            }
        }

        return results
    }

    private func buildSleepResult(
        sessionStart: Date?,
        sessionEnd: Date?,
        rawStages: [(timestamp: Date, stage: SleepStageType)],
        score: Int?,
        recoveryScore: Int? = nil,
        qualifier: String? = nil
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
            stages: stages,
            recoveryScore: recoveryScore,
            qualifier: qualifier
        )
    }
}
