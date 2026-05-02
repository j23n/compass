import SwiftUI
import Charts

/// Fullscreen chart detail for a single health metric.
/// Day range → scatter (hourly). Week / Month / Year → ranged bar chart.
/// Supports back/forward navigation through historical periods.
struct HealthDetailView: View {
    let metricTitle: String
    let metricUnit: String
    var color: Color = .blue
    var icon: String = "heart.fill"
    let data: [TrendDataPoint]      // all historical data — detail view filters internally
    var useBarChart: Bool = false
    var initialRange: TrendTimeRange = .week
    var valueFormatter: @Sendable (Double) -> String = { String(format: "%.0f", $0) }

    @State private var selectedRange: TrendTimeRange
    @State private var offset: Int = 0
    @State private var selectedPoint: TrendDataPoint?
    @State private var selectedBucket: TrendBucket?

    init(metricTitle: String, metricUnit: String, color: Color = .blue, icon: String = "heart.fill",
         data: [TrendDataPoint], useBarChart: Bool = false, initialRange: TrendTimeRange = .week,
         valueFormatter: @escaping @Sendable (Double) -> String = { String(format: "%.0f", $0) }) {
        self.metricTitle = metricTitle
        self.metricUnit = metricUnit
        self.color = color
        self.icon = icon
        self.data = data
        self.useBarChart = useBarChart
        self.initialRange = initialRange
        self.valueFormatter = valueFormatter
        _selectedRange = State(initialValue: initialRange)
    }

    // MARK: - Filtered data

    private var activeDateRange: ClosedRange<Date> { dateRange(for: selectedRange, offset: offset) }

    private var filteredData: [TrendDataPoint] {
        let r = activeDateRange
        return data.filter { r.contains($0.date) }
    }

    private var buckets: [TrendBucket] {
        makeTrendBuckets(from: data, range: selectedRange, isSum: useBarChart, offset: offset)
    }

    // Hourly buckets for the Day list view (keeps list to ≤24 rows regardless of sample density)
    private var dayHourBuckets: [TrendBucket] {
        guard selectedRange == .day else { return [] }
        let cal = Calendar.current
        let r = activeDateRange
        let start = r.lowerBound
        return (0..<24).compactMap { h in
            let s = cal.date(byAdding: .hour, value: h, to: start)!
            let e = cal.date(byAdding: .hour, value: 1, to: s)!
            guard s < r.upperBound else { return nil }
            let vals = filteredData.filter { $0.date >= s && $0.date < e }.map(\.value)
            guard !vals.isEmpty else { return nil }
            if useBarChart {
                let total = vals.reduce(0, +)
                return TrendBucket(date: s, low: 0, high: total, display: total)
            } else {
                let lo = vals.min()!, hi = vals.max()!
                return TrendBucket(date: s, low: lo, high: hi, display: vals.reduce(0, +) / Double(vals.count))
            }
        }
    }

    private var listBuckets: [TrendBucket] { selectedRange == .day ? dayHourBuckets : buckets }

    // MARK: - Display helpers

    private var averageDisplay: Double {
        let src = selectedRange == .day ? filteredData.map(\.value) : buckets.map(\.display)
        guard !src.isEmpty else { return 0 }
        return src.reduce(0, +) / Double(src.count)
    }

    private var minDisplay: Double {
        selectedRange == .day
            ? (filteredData.min(by: { $0.value < $1.value })?.value ?? 0)
            : (buckets.min(by: { $0.low < $1.low })?.low ?? 0)
    }

    private var maxDisplay: Double {
        selectedRange == .day
            ? (filteredData.max(by: { $0.value < $1.value })?.value ?? 0)
            : (buckets.max(by: { $0.high < $1.high })?.high ?? 0)
    }

    private var headerValue: String {
        if selectedRange == .day {
            return selectedPoint.map { valueFormatter($0.value) }
                ?? filteredData.last.map { valueFormatter($0.value) }
                ?? "--"
        } else {
            return selectedBucket.map { valueFormatter($0.display) }
                ?? buckets.last.map { valueFormatter($0.display) }
                ?? "--"
        }
    }

    private var headerDate: Date? {
        selectedRange == .day ? selectedPoint?.date : selectedBucket?.date
    }

    private var periodLabel: String {
        let r = activeDateRange
        let cal = Calendar.current
        switch selectedRange {
        case .day:
            if offset == 0 { return "Today" }
            if offset == -1 { return "Yesterday" }
            return r.lowerBound.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        case .week:
            let end = cal.date(byAdding: .day, value: -1, to: r.upperBound)!
            return "\(r.lowerBound.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.month(.abbreviated).day()))"
        case .month:
            let end = cal.date(byAdding: .day, value: -1, to: r.upperBound)!
            return "\(r.lowerBound.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.month(.abbreviated).day()))"
        case .year:
            let end = cal.date(byAdding: .month, value: -1, to: r.upperBound)!
            return "\(r.lowerBound.formatted(.dateTime.month(.abbreviated).year())) – \(end.formatted(.dateTime.month(.abbreviated).year()))"
        }
    }

    // MARK: - x-axis helpers

    private var xUnit: Calendar.Component { selectedRange == .year ? .month : .day }

    private var xDomain: ClosedRange<Date> { activeDateRange }

    private var calloutFormat: Date.FormatStyle {
        switch selectedRange {
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
                navigationControls
                chartSection
                statisticsSection
                if !listBuckets.isEmpty {
                    dataListSection
                }
            }
            .padding()
        }
        .navigationTitle(metricTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selectedRange) { _, _ in offset = 0; clearSelection() }
        .onChange(of: offset) { _, _ in clearSelection() }
    }

    private func clearSelection() {
        selectedPoint = nil
        selectedBucket = nil
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

    // MARK: - Navigation controls

    private var navigationControls: some View {
        HStack(spacing: 8) {
            Button {
                offset -= 1
            } label: {
                Image(systemName: "chevron.left")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .background(Color(.systemGray5))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            VStack(spacing: 2) {
                Picker("Range", selection: $selectedRange) {
                    ForEach(TrendTimeRange.allCases) { r in
                        Text(r.rawValue).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)

                Text(periodLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .animation(.easeInOut(duration: 0.15), value: offset)
            }

            Spacer()

            Button {
                offset += 1
            } label: {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .background(offset < 0 ? Color(.systemGray5) : Color(.systemGray5).opacity(0.3))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(offset >= 0)
        }
    }

    // MARK: - Chart

    @ViewBuilder
    private var chartSection: some View {
        if selectedRange == .day {
            if filteredData.isEmpty { emptyChart } else { scatterChart.frame(height: 300) }
        } else if buckets.isEmpty {
            emptyChart
        } else {
            barChart.frame(height: 300)
        }
    }

    private var emptyChart: some View {
        ContentUnavailableView {
            Label("No Data", systemImage: "chart.bar")
        } description: {
            Text("No \(metricTitle.lowercased()) data for this period.")
        }
        .frame(height: 300)
    }

    private var scatterChart: some View {
        Chart {
            ForEach(filteredData) { point in
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
        .chartXScale(domain: xDomain)
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
                            selectedPoint = filteredData.min(by: {
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
                        calloutView(value: barCalloutValue(b), date: b.date)
                    }
            }
        }
        .chartXScale(domain: xDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: selectedRange == .year ? 12 : 6)) { _ in
                AxisGridLine()
                AxisValueLabel(format: selectedRange == .year
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

    private func barCalloutValue(_ b: TrendBucket) -> String {
        useBarChart
            ? valueFormatter(b.display)
            : "\(valueFormatter(b.low)) – \(valueFormatter(b.high))"
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
        let hasData = selectedRange == .day ? !filteredData.isEmpty : !buckets.isEmpty
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

    // MARK: - Data list

    private var dataListSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(selectedRange == .day ? "Hourly Breakdown" : "Daily Summary")
                .font(.headline)
                .padding(.bottom, 12)

            ForEach(Array(listBuckets.reversed().enumerated()), id: \.offset) { idx, bucket in
                HStack {
                    Text(bucket.date, format: calloutFormat)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(useBarChart
                         ? valueFormatter(bucket.display)
                         : "\(valueFormatter(bucket.low)) – \(valueFormatter(bucket.high))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 9)
                if idx < listBuckets.count - 1 {
                    Divider()
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
