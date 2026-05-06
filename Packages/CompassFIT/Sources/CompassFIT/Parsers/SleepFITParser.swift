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

    private static let logger = Logger(subsystem: "com.compass.fit", category: "SleepValidation")

    public init(startDate: Date, endDate: Date, stage: SleepStageType) {
        self.startDate = startDate
        self.endDate = endDate
        self.stage = stage
    }

    /// Extracts the dominant real-sleep window from a sorted stage array.
    ///
    /// The Instinct Solar 1G emits many short "sleep" files per day during low-motion
    /// periods that aren't actually sleep. The distinguishing signal is sleep
    /// architecture: real sleep cycles through deep stages, while watch
    /// false-positives on quiet wakefulness produce light/rem without ever entering
    /// deep. This algorithm:
    ///
    /// 1. Splits stages into blocks separated by sustained awake gaps
    ///    (≥ `blockSplitGapMinutes`); short awake interruptions stay in the block.
    /// 2. Each block's `start` anchors to the first non-awake stage that begins
    ///    a run of `minContinuousNonAwakeMinutes`+; `end` anchors to the last
    ///    non-awake stage in a run of `minTrailingRunMinutes`+. Isolated rem/light
    ///    fragments at the edges before/after sustained sleep are trimmed away.
    /// 3. Filters blocks against quality thresholds (duration, deep minutes,
    ///    awake fraction, longest continuous non-awake run).
    /// 4. Returns the block with the most non-awake minutes; `nil` if none qualify.
    ///
    /// - Parameters:
    ///   - stages: Stages sorted ascending by `startDate`.
    ///   - blockSplitGapMinutes: An awake stretch this long or longer ends one
    ///     candidate block and starts a new one.
    ///   - minBlockDurationMinutes: Trimmed block duration (first→last non-awake)
    ///     must be at least this long.
    ///   - minDeepMinutes: A real sleep block must contain at least this many
    ///     minutes of deep sleep. This is the key noise filter — quiet-wake
    ///     misclassifications produce light/rem but rarely deep.
    ///   - minContinuousNonAwakeMinutes: A real sleep block must contain at least
    ///     one uninterrupted run of non-awake stages this long. Any awake stage
    ///     resets the run. Also the threshold for the leading-edge anchor: the
    ///     block's `start` is the beginning of the first run that reaches it.
    ///   - minTrailingRunMinutes: Threshold for the trailing-edge anchor: the
    ///     block's `end` is the end of the last run of non-awake stages that
    ///     reached this length. Lower than the leading threshold because brief
    ///     post-wake stages are usually still real sleep, while pre-sleep
    ///     fragments are usually noise.
    ///   - maxAwakeFraction: Awake minutes within the trimmed window may not exceed
    ///     this fraction of total within-window minutes.
    /// - Returns: `(start, end)` for the best-qualifying sleep block, or `nil`.
    public static func trimmedBounds(
        stages: [SleepStageResult],
        blockSplitGapMinutes: Int = 60,
        minBlockDurationMinutes: Int = 30,
        minDeepMinutes: Int = 5,
        minContinuousNonAwakeMinutes: Int = 30,
        minTrailingRunMinutes: Int = 10,
        maxAwakeFraction: Double = 0.6
    ) -> (start: Date, end: Date)? {
        guard !stages.isEmpty else { return nil }

        let blockSplitGap = TimeInterval(blockSplitGapMinutes * 60)
        let minBlockDur = TimeInterval(minBlockDurationMinutes * 60)
        let minDeep = TimeInterval(minDeepMinutes * 60)
        let minContRun = TimeInterval(minContinuousNonAwakeMinutes * 60)
        let minTrailRun = TimeInterval(minTrailingRunMinutes * 60)

        struct Block {
            var start: Date
            var end: Date
            /// Start of the first non-awake run in this block that reached
            /// `minContinuousNonAwakeMinutes`. Used as the block's reported
            /// start so fragmentary pre-sleep stages get trimmed away.
            /// Always non-nil when `longestNonAwakeRun ≥ minContRun`.
            var qualifyingStart: Date?
            /// End of the latest non-awake stage in a run that has reached
            /// `minTrailingRunMinutes`. Updates as long as the run continues;
            /// frozen when broken by awake. Used as the block's reported end
            /// so brief post-wake fragments get trimmed away.
            var trailingEnd: Date?
            var awake: TimeInterval = 0
            var light: TimeInterval = 0
            var deep: TimeInterval = 0
            var rem: TimeInterval = 0
            var longestNonAwakeRun: TimeInterval = 0
            var nonAwake: TimeInterval { light + deep + rem }
        }

        var blocks: [Block] = []
        var current: Block?
        // Awake duration accumulated since the last non-awake stage in `current`.
        // Committed to current.awake when the next non-awake stage extends the block;
        // discarded if the block closes (so trailing awake doesn't pollute the window).
        var awakePending: TimeInterval = 0
        // Continuous non-awake duration since the last awake stage. Any awake stage
        // resets this — even one that doesn't trigger a block split.
        var currentRun: TimeInterval = 0
        // Start of the first non-awake stage in the active run. Reset when the
        // run breaks. Promoted to `current.qualifyingStart` once the run reaches
        // `minContRun`.
        var currentRunStart: Date?

        for s in stages {
            let dur = s.endDate.timeIntervalSince(s.startDate)
            if s.stage == .awake {
                currentRun = 0
                currentRunStart = nil
                guard current != nil else { continue }      // ignore leading awake
                awakePending += dur
                if awakePending >= blockSplitGap {
                    blocks.append(current!)
                    current = nil
                    awakePending = 0
                }
            } else {
                if current == nil {
                    current = Block(start: s.startDate, end: s.endDate)
                } else {
                    current!.awake += awakePending
                }
                awakePending = 0
                current!.end = s.endDate
                switch s.stage {
                case .light: current!.light += dur
                case .deep:  current!.deep  += dur
                case .rem:   current!.rem   += dur
                case .awake: break
                }
                if currentRunStart == nil { currentRunStart = s.startDate }
                currentRun += dur
                if currentRun > current!.longestNonAwakeRun {
                    current!.longestNonAwakeRun = currentRun
                }
                if currentRun >= minContRun, current!.qualifyingStart == nil {
                    current!.qualifyingStart = currentRunStart
                }
                if currentRun >= minTrailRun {
                    current!.trailingEnd = s.endDate
                }
            }
        }
        if let c = current { blocks.append(c) }

        logger.debug("Validating \(blocks.count) candidate sleep block(s) from \(stages.count) stage(s)")

        let qualifying = blocks.filter { b in
            let dur = b.end.timeIntervalSince(b.start)
            let stats = "block \(b.start)–\(b.end) [dur=\(Int(dur/60))m deep=\(Int(b.deep/60))m light=\(Int(b.light/60))m rem=\(Int(b.rem/60))m awake=\(Int(b.awake/60))m run=\(Int(b.longestNonAwakeRun/60))m]"
            if dur < minBlockDur {
                logger.debug("Reject \(stats): duration < \(minBlockDurationMinutes)m")
                return false
            }
            if b.deep < minDeep {
                logger.debug("Reject \(stats): deep < \(minDeepMinutes)m")
                return false
            }
            if b.longestNonAwakeRun < minContRun {
                logger.debug("Reject \(stats): continuous non-awake run < \(minContinuousNonAwakeMinutes)m")
                return false
            }
            let total = b.awake + b.nonAwake
            guard total > 0 else {
                logger.debug("Reject \(stats): zero total time")
                return false
            }
            let frac = b.awake / total
            if frac > maxAwakeFraction {
                logger.debug("Reject \(stats): awake fraction \(Int(frac * 100))% > \(Int(maxAwakeFraction * 100))%")
                return false
            }
            logger.debug("Accept \(stats)")
            return true
        }

        guard let main = qualifying.max(by: { $0.nonAwake < $1.nonAwake }) else {
            logger.debug("No qualifying sleep block (rejected all \(blocks.count))")
            return nil
        }
        let trimmedStart = main.qualifyingStart ?? main.start
        let trimmedEnd = main.trailingEnd ?? main.end
        logger.debug("Selected sleep window \(trimmedStart)–\(trimmedEnd) (non-awake \(Int(main.nonAwake/60))m)")
        return (trimmedStart, trimmedEnd)
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
                   let ts = FITTimestamp.resolve(message) {
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
                if let ts = FITTimestamp.resolve(message) {
                    sessionEnd = ts
                }

            case .sleep_assessment:
                assessmentTimestamp = FITTimestamp.resolve(message)
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
        guard let timestamp = FITTimestamp.resolve(message),
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
            let ts = FITTimestamp.resolve(message)

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
