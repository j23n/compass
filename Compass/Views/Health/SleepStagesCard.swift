import SwiftUI
import Charts
import CompassData

/// Sleep visualization for the Health view.
///
/// - **Day**: a chronological timeline bar of last night's stages (matches the Today view).
/// - **Week / Month**: one stacked vertical bar per night, showing per-stage hours.
/// - **Year**: 12 monthly bars, each showing the average per-night sleep across that month
///   broken down by stage.
struct SleepStagesCard: View {
    let sessions: [SleepSession]
    var selectedRange: TrendTimeRange = .week

    private struct StageBucket: Identifiable {
        let id = UUID()
        let date: Date            // bucket start
        let label: String         // shown beneath the bar
        let deep: Double          // hours
        let rem: Double
        let light: Double
        let awake: Double
        var totalSleep: Double { deep + rem + light }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
            legend
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bed.double.fill")
                .foregroundStyle(.indigo)
            Text("Sleep")
                .font(.headline)
            Spacer()
            if selectedRange != .day, let avg = averageHoursPerNight {
                Text("avg \(formatHours(avg))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selectedRange {
        case .day:
            dayContent
        case .week, .month, .year:
            stackedBarsContent
        }
    }

    // MARK: - Day

    @ViewBuilder
    private var dayContent: some View {
        if let recent = mostRecentSession {
            let trimmed = recent.trimmedStages
            VStack(alignment: .leading, spacing: 8) {
                let total = recent.endDate.timeIntervalSince(recent.startDate)
                HStack(alignment: .firstTextBaseline) {
                    Text(formatDuration(total))
                        .font(.title3.bold())
                    Spacer()
                    Text("\(timeFmt(recent.startDate)) – \(timeFmt(recent.endDate))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                SleepTimelineBar(stages: trimmed, height: 28)
                    .frame(maxWidth: .infinity)
            }
        } else {
            Text("No sleep recorded.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var mostRecentSession: SleepSession? {
        sessions.max(by: { $0.endDate < $1.endDate })
    }

    // MARK: - Week / Month / Year stacked bars

    @ViewBuilder
    private var stackedBarsContent: some View {
        let bs = buckets
        if bs.isEmpty {
            Text("No sleep data in this window.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 180)
        } else {
            Chart {
                ForEach(bs) { bucket in
                    BarMark(x: .value("Date", bucket.label), y: .value("Hours", bucket.deep))
                        .foregroundStyle(SleepStageColor.color(for: .deep))
                        .annotation(position: .top, alignment: .center, spacing: 0) { EmptyView() }
                    BarMark(x: .value("Date", bucket.label), y: .value("Hours", bucket.rem))
                        .foregroundStyle(SleepStageColor.color(for: .rem))
                    BarMark(x: .value("Date", bucket.label), y: .value("Hours", bucket.light))
                        .foregroundStyle(SleepStageColor.color(for: .light))
                    BarMark(x: .value("Date", bucket.label), y: .value("Hours", bucket.awake))
                        .foregroundStyle(SleepStageColor.color(for: .awake))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine()
                    AxisValueLabel {
                        if let n = v.as(Double.self) {
                            Text("\(Int(n))h")
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: xAxisLabelCount)) { _ in
                    AxisValueLabel()
                }
            }
            .frame(height: 180)
        }
    }

    private var xAxisLabelCount: Int {
        switch selectedRange {
        case .day:   return 1
        case .week:  return 7
        case .month: return 6
        case .year:  return 12
        }
    }

    // MARK: - Bucketing

    private var buckets: [StageBucket] {
        switch selectedRange {
        case .day:
            return []
        case .week:
            return dailyBuckets(daysBack: 6, labelFormat: .dateTime.weekday(.abbreviated))
        case .month:
            return dailyBuckets(daysBack: 29, labelFormat: .dateTime.day())
        case .year:
            return monthlyBuckets()
        }
    }

    private func dailyBuckets(daysBack: Int, labelFormat: Date.FormatStyle) -> [StageBucket] {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -daysBack, to: todayStart)!

        // Group sessions by their endDate's day (the day they "belong to" — morning of).
        let grouped = Dictionary(grouping: sessions) { cal.startOfDay(for: $0.endDate) }

        return (0...daysBack).compactMap { offset in
            let day = cal.date(byAdding: .day, value: offset, to: start)!
            let dayKey = cal.startOfDay(for: day)
            let sessionsForDay = grouped[dayKey] ?? []
            let bucket = aggregate(sessionsForDay, date: day, label: day.formatted(labelFormat))
            return bucket.totalSleep + bucket.awake > 0 ? bucket : zeroBucket(date: day, label: day.formatted(labelFormat))
        }
    }

    private func monthlyBuckets() -> [StageBucket] {
        let cal = Calendar.current
        let now = Date()
        let thisMonth = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        let startMonth = cal.date(byAdding: .month, value: -11, to: thisMonth)!

        return (0..<12).map { offset in
            let monthStart = cal.date(byAdding: .month, value: offset, to: startMonth)!
            let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart)!
            let inMonth = sessions.filter { $0.endDate >= monthStart && $0.endDate < monthEnd }
            let label = monthStart.formatted(.dateTime.month(.narrow))
            let nightsCount = max(1, inMonth.count)
            // Average per night, broken down by stage. Use trimmed stages so
            // leading/trailing awake noise doesn't inflate the awake band.
            let totalDeep  = inMonth.reduce(0.0) { $0 + $1.trimmedStages.duration(for: .deep) }
            let totalRem   = inMonth.reduce(0.0) { $0 + $1.trimmedStages.duration(for: .rem) }
            let totalLight = inMonth.reduce(0.0) { $0 + $1.trimmedStages.duration(for: .light) }
            let totalAwake = inMonth.reduce(0.0) { $0 + $1.trimmedStages.duration(for: .awake) }
            return StageBucket(
                date: monthStart,
                label: label,
                deep: totalDeep / Double(nightsCount) / 3600.0,
                rem: totalRem / Double(nightsCount) / 3600.0,
                light: totalLight / Double(nightsCount) / 3600.0,
                awake: totalAwake / Double(nightsCount) / 3600.0
            )
        }
    }

    private func aggregate(_ sessions: [SleepSession], date: Date, label: String) -> StageBucket {
        let deep  = sessions.reduce(0.0) { $0 + $1.trimmedStages.duration(for: .deep) } / 3600.0
        let rem   = sessions.reduce(0.0) { $0 + $1.trimmedStages.duration(for: .rem) } / 3600.0
        let light = sessions.reduce(0.0) { $0 + $1.trimmedStages.duration(for: .light) } / 3600.0
        let awake = sessions.reduce(0.0) { $0 + $1.trimmedStages.duration(for: .awake) } / 3600.0
        return StageBucket(date: date, label: label, deep: deep, rem: rem, light: light, awake: awake)
    }

    private func zeroBucket(date: Date, label: String) -> StageBucket {
        StageBucket(date: date, label: label, deep: 0, rem: 0, light: 0, awake: 0)
    }

    // MARK: - Legend / averages

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(SleepStageColor.displayOrder, id: \.self) { stage in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(SleepStageColor.color(for: stage))
                        .frame(width: 10, height: 10)
                    Text(stage.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var averageHoursPerNight: Double? {
        let bs = buckets.filter { $0.totalSleep > 0 }
        guard !bs.isEmpty else { return nil }
        let total = bs.reduce(0.0) { $0 + $1.totalSleep }
        return total / Double(bs.count)
    }

    private func formatHours(_ hours: Double) -> String {
        let h = Int(hours)
        let m = Int((hours - Double(h)) * 60)
        return "\(h)h \(m)m"
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let h = Int(interval) / 3600
        let m = (Int(interval) % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    private func timeFmt(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }
}
