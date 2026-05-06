import Foundation
import CompassData

/// One stage interval within a `SleepStageBucket`. `startHour`/`endHour` are
/// hours since the bucket's `anchor` (noon of the day before the bucket's date),
/// so y-axis values fall in roughly `0...24` and align with time-of-day.
struct SleepStageSegment: Identifiable, Sendable {
    let id = UUID()
    let stage: SleepStageType
    let startHour: Double
    let endHour: Double
}

/// One night's sleep, attributed to the calendar day the user woke up. The
/// chart plots `segments` at their actual time-of-day so consistent
/// bedtime/wake-time patterns become visible across nights.
struct SleepStageBucket: Identifiable, Sendable {
    let id = UUID()
    /// X-axis: the day this night "belongs to" (startOfDay of the session's endDate).
    let date: Date
    /// Y-axis reference: noon of the day before `date`. `startHour=0` means
    /// noon-yesterday, `12` is midnight, `24` is noon-today.
    let anchor: Date
    let segments: [SleepStageSegment]
    let perStage: [SleepStageType: Double]   // hours per stage
    /// Earliest non-awake startHour across the night.
    let bedHour: Double?
    /// Latest non-awake endHour across the night.
    let wakeHour: Double?

    var totalSleep: Double { perStage.values.reduce(0, +) }
    func duration(for stage: SleepStageType) -> Double { perStage[stage] ?? 0 }

    var bedTime: Date? { bedHour.map { anchor.addingTimeInterval($0 * 3600) } }
    var wakeTime: Date? { wakeHour.map { anchor.addingTimeInterval($0 * 3600) } }
}

/// Buckets sleep sessions into one entry per night (attributed by wake-day) for
/// the given range/offset. Each segment's `startHour`/`endHour` is the actual
/// stage time mapped onto a 0–24 hour axis anchored at noon of the prior day.
/// Empty days are dropped.
func makeSleepStageBuckets(
    from sessions: [SleepSession],
    range: TrendTimeRange,
    offset: Int = 0
) -> [SleepStageBucket] {
    let cal = Calendar.current
    let now = Date()
    let todayStart = cal.startOfDay(for: now)

    let days: [Date]
    switch range {
    case .day:
        days = [cal.date(byAdding: .day, value: offset, to: todayStart)!]
    case .week:
        let anchor = cal.date(byAdding: .day, value: offset * 7, to: todayStart)!
        let start = cal.date(byAdding: .day, value: -6, to: anchor)!
        days = (0..<7).map { cal.date(byAdding: .day, value: $0, to: start)! }
    case .month:
        let anchor = cal.date(byAdding: .day, value: offset * 30, to: todayStart)!
        let start = cal.date(byAdding: .day, value: -29, to: anchor)!
        days = (0..<30).map { cal.date(byAdding: .day, value: $0, to: start)! }
    case .year:
        let thisMonth = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        let yearAnchor = cal.date(byAdding: .month, value: offset * 12, to: thisMonth)!
        let start = cal.date(byAdding: .month, value: -11, to: yearAnchor)!
        let end = cal.date(byAdding: .month, value: 1, to: yearAnchor)!
        var list: [Date] = []
        var d = start
        while d < end {
            list.append(d)
            d = cal.date(byAdding: .day, value: 1, to: d)!
        }
        days = list
    }

    // Group sessions by wake-day so each bucket only iterates its own night(s).
    let sessionsByDay = Dictionary(grouping: sessions) { cal.startOfDay(for: $0.endDate) }

    return days.compactMap { day -> SleepStageBucket? in
        guard let daySessions = sessionsByDay[day], !daySessions.isEmpty else { return nil }
        let anchor = cal.date(byAdding: .hour, value: -12, to: day)!

        var segments: [SleepStageSegment] = []
        var perStage: [SleepStageType: Double] = [:]
        var bedHour: Double = .infinity
        var wakeHour: Double = -.infinity

        for session in daySessions {
            for stage in session.trimmedStages {
                let startH = stage.startDate.timeIntervalSince(anchor) / 3600.0
                let endH   = stage.endDate.timeIntervalSince(anchor)   / 3600.0
                let dur = endH - startH
                guard dur > 0 else { continue }
                segments.append(SleepStageSegment(stage: stage.stage, startHour: startH, endHour: endH))
                perStage[stage.stage, default: 0] += dur
                if stage.stage != .awake {
                    if startH < bedHour { bedHour = startH }
                    if endH > wakeHour { wakeHour = endH }
                }
            }
        }

        guard !segments.isEmpty else { return nil }

        return SleepStageBucket(
            date: day,
            anchor: anchor,
            segments: segments,
            perStage: perStage,
            bedHour: bedHour.isFinite ? bedHour : nil,
            wakeHour: wakeHour.isFinite ? wakeHour : nil
        )
    }
}

/// Formats a 0–24 hour offset (anchored at noon of the previous day) as a
/// 12-hour wall-clock label suitable for chart y-axis ticks.
func formatSleepHour(_ hour: Double) -> String {
    let h = ((Int(hour.rounded()) + 12) % 24 + 24) % 24
    if h == 0 { return "12 AM" }
    if h == 12 { return "12 PM" }
    if h < 12 { return "\(h) AM" }
    return "\(h - 12) PM"
}
