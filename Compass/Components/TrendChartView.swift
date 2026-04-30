import SwiftUI
import Charts

/// Time range options for trend charts.
enum TrendTimeRange: String, CaseIterable, Identifiable {
    case day = "Day"
    case week = "Week"
    case month = "Month"
    case year = "Year"

    var id: String { rawValue }
}

/// A data point for trend charts.
struct TrendDataPoint: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let value: Double
}

/// An aggregated bucket for ranged bar charts (week / month / year views).
struct TrendBucket: Identifiable, Sendable {
    let id = UUID()
    let date: Date      // bucket start (day or month)
    let low: Double     // bar bottom: 0 for sum metrics, actual min for range metrics
    let high: Double    // bar top:    total for sum, actual max for range
    let display: Double // shown in callout: total for sum, average for range
}

/// Groups `data` into calendar buckets for the given range.
/// - `isSum`: true for totals (steps, sleep), false for min/max ranges (HR, BB, stress).
/// Day range is a no-op (scatter handled separately).
func makeTrendBuckets(from data: [TrendDataPoint], range: TrendTimeRange, isSum: Bool) -> [TrendBucket] {
    guard range != .day else { return [] }
    let cal = Calendar.current
    let now = Date()
    let todayStart = cal.startOfDay(for: now)

    let startDate: Date
    let unit: Calendar.Component
    let count: Int

    switch range {
    case .day: return []
    case .week:
        startDate = cal.date(byAdding: .day, value: -6, to: todayStart)!
        unit = .day; count = 7
    case .month:
        startDate = cal.date(byAdding: .day, value: -29, to: todayStart)!
        unit = .day; count = 30
    case .year:
        let thisMonth = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        startDate = cal.date(byAdding: .month, value: -11, to: thisMonth)!
        unit = .month; count = 12
    }

    return (0..<count).compactMap { i in
        let bucketStart = cal.date(byAdding: unit, value: i, to: startDate)!
        let bucketEnd   = cal.date(byAdding: unit, value: 1, to: bucketStart)!
        guard bucketStart <= now else { return nil }
        let vals = data.filter { $0.date >= bucketStart && $0.date < bucketEnd }.map { $0.value }
        guard !vals.isEmpty else { return nil }
        if isSum {
            let total = vals.reduce(0, +)
            return TrendBucket(date: bucketStart, low: 0, high: total, display: total)
        } else {
            let lo = vals.min()!, hi = vals.max()!
            let avg = vals.reduce(0, +) / Double(vals.count)
            return TrendBucket(date: bucketStart, low: lo, high: hi, display: avg)
        }
    }
}

/// A reusable trend chart with time range picker and tap-to-inspect callout.
struct TrendChartView: View {
    let title: String
    var color: Color = .blue
    let data: [TrendDataPoint]
    var valueFormatter: @Sendable (Double) -> String = { String(format: "%.0f", $0) }

    @Binding var selectedRange: TrendTimeRange

    @State private var selectedDataPoint: TrendDataPoint?
    @State private var selectedXPosition: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            Picker("Time Range", selection: $selectedRange) {
                ForEach(TrendTimeRange.allCases) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .pickerStyle(.segmented)

            chartContent
                .frame(height: 200)
        }
    }

    @ViewBuilder
    private var chartContent: some View {
        Chart {
            ForEach(data) { point in
                PointMark(
                    x: .value("Date", point.date),
                    y: .value("Value", point.value)
                )
                .foregroundStyle(color.opacity(0.75))
                .symbolSize(30)
            }

            if let selected = selectedDataPoint {
                RuleMark(x: .value("Selected", selected.date))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, spacing: 4) {
                        VStack(spacing: 2) {
                            Text(valueFormatter(selected.value))
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundStyle(.primary)
                            Text(selected.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white)
                                .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.gray.opacity(0.2), lineWidth: 0.5)
                        }
                        .colorScheme(.light)
                    }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                let xPosition = drag.location.x
                                guard let date: Date = proxy.value(atX: xPosition) else { return }
                                // Find nearest data point
                                selectedDataPoint = data.min(by: {
                                    abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
                                })
                            }
                            .onEnded { _ in
                                selectedDataPoint = nil
                            }
                    )
            }
        }
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var range: TrendTimeRange = .week

        var body: some View {
            TrendChartView(
                title: "Resting Heart Rate",
                color: .red,
                data: sampleTrendData(),
                valueFormatter: { "\(Int($0)) bpm" },
                selectedRange: $range
            )
            .padding()
        }

        func sampleTrendData() -> [TrendDataPoint] {
            let calendar = Calendar.current
            let today = Date()
            return (0..<14).map { dayOffset in
                let date = calendar.date(byAdding: .day, value: -dayOffset, to: today)!
                let value = Double.random(in: 55...65)
                return TrendDataPoint(date: date, value: value)
            }.reversed()
        }
    }

    return PreviewWrapper()
}
