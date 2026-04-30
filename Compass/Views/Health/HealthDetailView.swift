import SwiftUI
import Charts

/// Fullscreen chart detail for a single health metric.
/// Day range → scatter plot. Week / Month / Year → ranged bar chart.
struct HealthDetailView: View {
    let metricTitle: String
    let metricUnit: String
    var color: Color = .blue
    var icon: String = "heart.fill"
    let data: [TrendDataPoint]
    var useBarChart: Bool = false
    var initialRange: TrendTimeRange = .week
    var valueFormatter: @Sendable (Double) -> String = { String(format: "%.0f", $0) }

    @State private var selectedPoint: TrendDataPoint?
    @State private var selectedBucket: TrendBucket?

    private var buckets: [TrendBucket] {
        makeTrendBuckets(from: data, range: initialRange, isSum: useBarChart)
    }

    private var averageDisplay: Double {
        let src = initialRange == .day ? data.map(\.value) : buckets.map(\.display)
        guard !src.isEmpty else { return 0 }
        return src.reduce(0, +) / Double(src.count)
    }

    private var minDisplay: Double {
        initialRange == .day
            ? (data.min(by: { $0.value < $1.value })?.value ?? 0)
            : (buckets.min(by: { $0.low < $1.low })?.low ?? 0)
    }

    private var maxDisplay: Double {
        initialRange == .day
            ? (data.max(by: { $0.value < $1.value })?.value ?? 0)
            : (buckets.max(by: { $0.high < $1.high })?.high ?? 0)
    }

    private var headerValue: String {
        if initialRange == .day {
            return selectedPoint.map { valueFormatter($0.value) }
                ?? data.last.map { valueFormatter($0.value) }
                ?? "--"
        } else {
            return selectedBucket.map { valueFormatter($0.display) }
                ?? buckets.last.map { valueFormatter($0.display) }
                ?? "--"
        }
    }

    private var headerDate: Date? {
        initialRange == .day ? selectedPoint?.date : selectedBucket?.date
    }

    // MARK: - x-axis helpers

    private var xUnit: Calendar.Component { initialRange == .year ? .month : .day }

    private var xDomain: ClosedRange<Date> {
        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)
        let todayEnd   = cal.date(byAdding: .day, value: 1, to: todayStart)!
        switch initialRange {
        case .day:
            return todayStart...todayEnd
        case .week:
            return cal.date(byAdding: .day, value: -6, to: todayStart)!...todayEnd
        case .month:
            return cal.date(byAdding: .day, value: -29, to: todayStart)!...todayEnd
        case .year:
            let thisMonth = cal.date(from: cal.dateComponents([.year, .month], from: now))!
            return cal.date(byAdding: .month, value: -11, to: thisMonth)!...todayEnd
        }
    }

    private var calloutFormat: Date.FormatStyle {
        switch initialRange {
        case .day:   return .dateTime.hour().minute()
        case .week:  return .dateTime.weekday(.abbreviated).month(.abbreviated).day()
        case .month: return .dateTime.month(.abbreviated).day()
        case .year:  return .dateTime.month(.wide)
        }
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection
                chartSection
                statisticsSection
            }
            .padding()
        }
        .navigationTitle(metricTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 44, height: 44)
                .background(color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(headerValue)
                    .font(.largeTitle).fontWeight(.bold).foregroundStyle(.primary)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.15), value: headerDate)

                if let d = headerDate {
                    Text(d, format: calloutFormat)
                        .font(.subheadline).foregroundStyle(.secondary)
                } else if !metricUnit.isEmpty {
                    Text(metricUnit)
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    // MARK: - Chart

    @ViewBuilder
    private var chartSection: some View {
        if initialRange == .day {
            scatterChart
                .frame(height: 300)
        } else if buckets.isEmpty {
            ContentUnavailableView {
                Label("No Data", systemImage: "chart.bar")
            } description: {
                Text("No \(metricTitle.lowercased()) data available.")
            }
            .frame(height: 300)
        } else {
            barChart
                .frame(height: 300)
        }
    }

    private var scatterChart: some View {
        Chart {
            ForEach(data) { point in
                PointMark(
                    x: .value("Date", point.date),
                    y: .value("Value", point.value)
                )
                .foregroundStyle(color.opacity(0.75))
                .symbolSize(35)
            }
            if let pt = selectedPoint {
                RuleMark(x: .value("Selected", pt.date))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit, y: .disabled)) {
                        calloutView(value: valueFormatter(pt.value), date: pt.date)
                    }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .chartOverlay { proxy in
            GeometryReader { _ in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            guard let date: Date = proxy.value(atX: drag.location.x) else { return }
                            selectedPoint = data.min(by: {
                                abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
                            })
                        }
                        .onEnded { _ in selectedPoint = nil })
            }
        }
    }

    private var barChart: some View {
        Chart {
            ForEach(buckets) { bucket in
                BarMark(
                    x: .value("Date", bucket.date, unit: xUnit),
                    yStart: .value("Low",  bucket.low),
                    yEnd:   .value("High", bucket.high)
                )
                .foregroundStyle(LinearGradient(
                    colors: [color.opacity(0.85), color.opacity(0.45)],
                    startPoint: .top, endPoint: .bottom
                ))
                .cornerRadius(4)
            }
            if let b = selectedBucket {
                RuleMark(x: .value("Selected", b.date, unit: xUnit))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit, y: .disabled)) {
                        calloutView(value: valueFormatter(b.display), date: b.date)
                    }
            }
        }
        .chartXScale(domain: xDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: initialRange == .year ? 12 : 6)) { _ in
                AxisGridLine()
                AxisValueLabel(format: initialRange == .year
                    ? .dateTime.month(.abbreviated)
                    : .dateTime.month(.abbreviated).day())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .chartOverlay { proxy in
            GeometryReader { _ in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            guard let date: Date = proxy.value(atX: drag.location.x) else { return }
                            selectedBucket = buckets.min(by: {
                                abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
                            })
                        }
                        .onEnded { _ in selectedBucket = nil })
            }
        }
    }

    private func calloutView(value: String, date: Date) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.caption).fontWeight(.semibold).foregroundStyle(.primary)
            Text(date, format: calloutFormat)
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
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

    // MARK: - Statistics

    @ViewBuilder
    private var statisticsSection: some View {
        let hasData = initialRange == .day ? !data.isEmpty : !buckets.isEmpty
        if hasData {
            VStack(alignment: .leading, spacing: 16) {
                Text("Statistics").font(.headline)
                Grid(horizontalSpacing: 16, verticalSpacing: 12) {
                    GridRow {
                        statItem(label: "Average", value: valueFormatter(averageDisplay))
                        statItem(label: "Min",     value: valueFormatter(minDisplay))
                        statItem(label: "Max",     value: valueFormatter(maxDisplay))
                    }
                }
            }
            .padding()
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.background)
                    .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 2)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
        }
    }

    private func statItem(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3).fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    let sampleData: [TrendDataPoint] = (0..<14).map { offset in
        TrendDataPoint(
            date: Calendar.current.date(byAdding: .day, value: -offset, to: Date())!,
            value: Double.random(in: 55...68)
        )
    }.reversed()

    NavigationStack {
        HealthDetailView(
            metricTitle: "Resting Heart Rate",
            metricUnit: "bpm",
            color: .red,
            icon: "heart.fill",
            data: sampleData,
            valueFormatter: { "\(Int($0)) bpm" }
        )
    }
}
