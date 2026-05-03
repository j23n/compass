import SwiftUI
import Charts

/// A health metric card with a polished chart and drag-to-read interaction.
/// Day range → scatter plot. Week / Month / Year → ranged bar chart bucketed by day or month.
struct InteractiveTrendCard: View {
    let title: String
    let icon: String
    let color: Color
    let unit: String
    let data: [TrendDataPoint]
    var useBarChart: Bool = false   // true = sum metric (steps/sleep); false = range metric (HR/BB/stress)
    var selectedRange: TrendTimeRange = .week
    let valueFormatter: @Sendable (Double) -> String

    @State private var selectedPoint: TrendDataPoint?   // day scatter selection
    @State private var selectedBucket: TrendBucket?     // week/month/year bar selection

    // For Day scatter: filter to the current day only (data contains all-time history).
    private var displayData: [TrendDataPoint] {
        guard selectedRange == .day else { return data }
        let r = dateRange(for: .day, offset: 0)
        return data.filter { r.contains($0.date) }
    }

    // Pre-computed buckets for non-day ranges.
    private var buckets: [TrendBucket] {
        makeTrendBuckets(from: data, range: selectedRange, isSum: useBarChart)
    }

    private var displayValue: String {
        if selectedRange == .day {
            return selectedPoint.map { valueFormatter($0.value) }
                ?? displayData.last.map { valueFormatter($0.value) }
                ?? "--"
        } else {
            return selectedBucket.map { valueFormatter($0.display) }
                ?? buckets.last.map { valueFormatter($0.display) }
                ?? "--"
        }
    }

    private var selectionActive: Bool {
        selectedRange == .day ? selectedPoint != nil : selectedBucket != nil
    }

    // MARK: - x-axis helpers (bar chart)

    private var xUnit: Calendar.Component { selectedRange == .year ? .month : .day }

    private func bucketCenterDate(_ date: Date) -> Date {
        let cal = Calendar.current
        switch xUnit {
        case .hour:  return cal.date(byAdding: .minute, value: 30, to: date) ?? date
        case .day:   return cal.date(byAdding: .hour,   value: 12, to: date) ?? date
        case .month:
            let range = cal.range(of: .day, in: .month, for: date) ?? 1..<31
            let half  = range.count / 2
            return cal.date(byAdding: .day, value: half, to: date) ?? date
        default: return date
        }
    }

    private var xDomain: ClosedRange<Date> {
        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)
        let todayEnd   = cal.date(byAdding: .day, value: 1, to: todayStart)!
        switch selectedRange {
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

    private var barAxisStride: Calendar.Component {
        switch selectedRange {
        case .day:         return .hour     // unused
        case .week:        return .day
        case .month:       return .day
        case .year:        return .month
        }
    }

    private var barAxisStrideCount: Int {
        switch selectedRange {
        case .day:   return 1
        case .week:  return 1   // every day → 7 labels
        case .month: return 7   // every week → ~4 labels
        case .year:  return 1   // every month → 12 labels
        }
    }

    private var barAxisFormat: Date.FormatStyle {
        switch selectedRange {
        case .day:         return .dateTime.hour()
        case .week:        return .dateTime.weekday(.abbreviated)
        case .month:       return .dateTime.day()
        case .year:        return .dateTime.month(.abbreviated)
        }
    }

    private var calloutFormat: Date.FormatStyle {
        switch selectedRange {
        case .day:         return .dateTime.hour().minute()
        case .week:        return .dateTime.weekday(.abbreviated).month(.abbreviated).day()
        case .month:       return .dateTime.month(.abbreviated).day()
        case .year:        return .dateTime.month(.wide)
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationLink {
                HealthDetailView(
                    metricTitle: title,
                    metricUnit: unit,
                    color: color,
                    icon: icon,
                    data: data,          // all-time data; HealthDetailView filters internally
                    useBarChart: useBarChart,
                    initialRange: selectedRange,
                    valueFormatter: valueFormatter
                )
            } label: {
                cardHeader
            }
            .buttonStyle(.plain)

            Divider()
                .padding(.vertical, 10)

            if selectedRange == .day {
                if displayData.isEmpty { emptyChart } else { scatterChart.frame(height: 120) }
            } else {
                if buckets.isEmpty { emptyChart } else { barChart.frame(height: 120) }
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

    // MARK: - Header

    private var cardHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(color)
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
            Spacer()
            Text(displayValue)
                .font(.subheadline)
                .foregroundStyle(selectionActive ? color : .secondary)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.15), value: selectionActive)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Scatter chart (Day)

    private var scatterChart: some View {
        Chart {
            ForEach(displayData) { point in
                PointMark(
                    x: .value("Date", point.date),
                    y: .value("Value", point.value)
                )
                .foregroundStyle(color.opacity(0.75))
                .symbolSize(25)
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
        .chartXScale(domain: xDomain)
        .chartYScale(domain: ChartYDomain.niceDomain(for: displayData.map(\.value)))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
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
                            selectedPoint = displayData.min(by: {
                                abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
                            })
                        }
                        .onEnded { _ in selectedPoint = nil })
            }
        }
    }

    // MARK: - Bar chart (Week / Month / Year)

    private var barChart: some View {
        let yVals = useBarChart ? buckets.map(\.high) : buckets.flatMap { [$0.low, $0.high] }
        let domain = useBarChart
            ? ChartYDomain.zeroAnchored(for: yVals)
            : ChartYDomain.niceDomain(for: yVals)
        return Chart {
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
                .cornerRadius(3)
            }
            if let b = selectedBucket {
                RuleMark(x: .value("Selected", bucketCenterDate(b.date)))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit, y: .disabled)) {
                        calloutView(value: barCalloutValue(b), date: b.date)
                    }
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: domain)
        .chartXAxis {
            AxisMarks(values: .stride(by: barAxisStride, count: barAxisStrideCount)) { _ in
                AxisValueLabel(format: barAxisFormat)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
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
                            let containing = buckets.first { $0.date <= date && date < $0.endDate }
                            selectedBucket = containing ?? buckets.last
                        }
                        .onEnded { _ in selectedBucket = nil })
            }
        }
    }

    private func barCalloutValue(_ b: TrendBucket) -> String {
        useBarChart
            ? valueFormatter(b.display)
            : "\(valueFormatter(b.low)) – \(valueFormatter(b.high))"
    }

    // MARK: - Shared callout

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

    private var emptyChart: some View {
        Text("No data available")
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
    }
}
