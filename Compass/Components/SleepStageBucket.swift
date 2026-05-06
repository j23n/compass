import Foundation
import CompassData

/// One stacked segment of a `SleepStageBucket`. `low`/`high` are cumulative
/// hours so the chart can render each segment with `BarMark(yStart:yEnd:)`.
struct SleepStageSegment: Identifiable, Sendable {
    let id = UUID()
    let stage: SleepStageType
    let low: Double   // hours
    let high: Double  // hours
}

/// One x-axis bucket for the sleep stage chart. Each bucket holds the total
/// time spent in each stage during that period (in hours), pre-stacked into
/// segments in `SleepStageColor.displayOrder`.
struct SleepStageBucket: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let perStage: [SleepStageType: Double]  // hours per stage

    var total: Double { perStage.values.reduce(0, +) }

    func duration(for stage: SleepStageType) -> Double { perStage[stage] ?? 0 }

    var segments: [SleepStageSegment] {
        var cum: Double = 0
        var out: [SleepStageSegment] = []
        for stage in SleepStageColor.displayOrder {
            let dur = perStage[stage] ?? 0
            guard dur > 0 else { continue }
            out.append(SleepStageSegment(stage: stage, low: cum, high: cum + dur))
            cum += dur
        }
        return out
    }
}

/// Buckets sleep stage durations across `sessions` into the chart grid for
/// `range`/`offset`. Stages are clipped to each bucket's interval, so partial
/// overlaps (e.g. a session that starts before the bucket starts) contribute
/// only the overlapping portion. Empty buckets are dropped.
func makeSleepStageBuckets(
    from sessions: [SleepSession],
    range: TrendTimeRange,
    offset: Int = 0
) -> [SleepStageBucket] {
    let cal = Calendar.current
    let now = Date()
    let todayStart = cal.startOfDay(for: now)

    let bucketStarts: [Date]
    let unit: Calendar.Component
    let step: Int

    switch range {
    case .day:
        let s = cal.date(byAdding: .day, value: offset, to: todayStart)!
        bucketStarts = (0..<24).map { cal.date(byAdding: .hour, value: $0, to: s)! }
        unit = .hour; step = 1
    case .week:
        let anchor = cal.date(byAdding: .day, value: offset * 7, to: todayStart)!
        let start = cal.date(byAdding: .day, value: -6, to: anchor)!
        bucketStarts = (0..<7).map { cal.date(byAdding: .day, value: $0, to: start)! }
        unit = .day; step = 1
    case .month:
        let anchor = cal.date(byAdding: .day, value: offset * 30, to: todayStart)!
        let start = cal.date(byAdding: .day, value: -29, to: anchor)!
        bucketStarts = (0..<30).map { cal.date(byAdding: .day, value: $0, to: start)! }
        unit = .day; step = 1
    case .year:
        let thisMonth = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        let anchor = cal.date(byAdding: .month, value: offset * 12, to: thisMonth)!
        let start = cal.date(byAdding: .month, value: -11, to: anchor)!
        bucketStarts = (0..<12).map { cal.date(byAdding: .month, value: $0, to: start)! }
        unit = .month; step = 1
    }

    return bucketStarts.compactMap { bStart -> SleepStageBucket? in
        let bEnd = cal.date(byAdding: unit, value: step, to: bStart)!
        var perStage: [SleepStageType: Double] = [:]
        for session in sessions where session.endDate > bStart && session.startDate < bEnd {
            for stage in session.trimmedStages {
                let lo = max(stage.startDate, bStart)
                let hi = min(stage.endDate, bEnd)
                let overlap = hi.timeIntervalSince(lo)
                if overlap > 0 {
                    perStage[stage.stage, default: 0] += overlap / 3600.0
                }
            }
        }
        guard !perStage.isEmpty else { return nil }
        return SleepStageBucket(date: bStart, perStage: perStage)
    }
}
