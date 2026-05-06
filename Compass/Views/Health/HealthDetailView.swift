import SwiftUI
import Charts

/// Fullscreen chart detail for a single health metric.
/// All ranges → ranged bar chart. Day range uses hourly buckets; Week/Month/Year use daily/monthly.
/// Supports back/forward navigation through historical periods.
struct HealthDetailView: View {
    let metricTitle: String
    let metricUnit: String
    var color: Color = .blue
    var icon: String = "heart.fill"
    let data: [TrendDataPoint]      // all historical data — detail view filters internally
    /// Per-sample source for the Day chart. Used in place of `data` when the
    /// selected range is `.day`, so metrics whose `data` is a daily roll-up
    /// (one entry per day at midnight, e.g. `StepCount`) can still render an
    /// hourly distribution from finer-grained samples (e.g. `StepSample`).
    var dayData: [TrendDataPoint]? = nil
    var useBarChart: Bool = false
    var initialRange: TrendTimeRange = .week
    var valueFormatter: @Sendable (Double) -> String = { String(format: "%.0f", $0) }

    @State private var selectedRange: TrendTimeRange
    @State private var offset: Int = 0
    @State private var selectedBucket: TrendBucket?
    @State private var showingTotalInfo: Bool = false

    init(metricTitle: String, metricUnit: String, color: Color = .blue, icon: String = "heart.fill",
         data: [TrendDataPoint], dayData: [TrendDataPoint]? = nil,
         useBarChart: Bool = false, initialRange: TrendTimeRange = .week,
         valueFormatter: @escaping @Sendable (Double) -> String = { String(format: "%.0f", $0) }) {
        self.metricTitle = metricTitle
        self.metricUnit = metricUnit
        self.color = color
        self.icon = icon
        self.data = data
        self.dayData = dayData
        self.useBarChart = useBarChart
        self.initialRange = initialRange
        self.valueFormatter = valueFormatter
        _selectedRange = State(initialValue: initialRange)
    }

    // MARK: - Filtered data

    private var activeDateRange: ClosedRange<Date> { dateRange(for: selectedRange, offset: offset) }

    private var filteredData: [TrendDataPoint] {
        let r = activeDateRange
        let source = (selectedRange == .day ? (dayData ?? data) : data)
        return source.filter { r.contains($0.date) }
    }

    private var buckets: [TrendBucket] {
        makeTrendBuckets(from: data, range: selectedRange, isSum: useBarChart, offset: offset)
    }

    // All 24 hourly slots for Day chart (empty hours included as zero bars).
    private var dayChartBuckets: [TrendBucket] {
        guard selectedRange == .day else { return [] }
        let cal = Calendar.current
        let r = activeDateRange
        let start = r.lowerBound
        return (0..<24).compactMap { h in
            let s = cal.date(byAdding: .hour, value: h, to: start)!
            let e = cal.date(byAdding: .hour, value: 1, to: s)!
            guard s < r.upperBound else { return nil }
            let vals = filteredData.filter { $0.date >= s && $0.date < e }.map(\.value)
            if useBarChart {
                let total = vals.reduce(0, +)
                return TrendBucket(date: s, low: 0, high: total, display: total)
            } else {
                let lo = vals.min() ?? 0
                let hi = vals.max() ?? 0
                let avg = vals.isEmpty ? 0 : vals.reduce(0, +) / Double(vals.count)
                return TrendBucket(date: s, low: lo, high: hi, display: avg)
            }
        }
    }

    // Hourly buckets for the Day list view (non-empty hours only).
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

    private var sourceValues: [Double] {
        selectedRange == .day ? filteredData.map(\.value) : buckets.map(\.display)
    }

    private var averageDisplay: Double {
        let src = sourceValues
        guard !src.isEmpty else { return 0 }
        return src.reduce(0, +) / Double(src.count)
    }

    private var stdDevDisplay: Double {
        let v = sourceValues
        guard v.count > 1 else { return 0 }
        let mean = v.reduce(0, +) / Double(v.count)
        let variance = v.reduce(0) { $0 + pow($1 - mean, 2) } / Double(v.count - 1)
        return sqrt(variance)
    }

    private var sampleCount: Int { sourceValues.count }

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

    /// Sum of `data` (the period rollup, *not* `dayData`) within the active
    /// range — used for the Day-graph header on sum-shaped metrics so it shows
    /// the authoritative day total even when bars come from a finer-grained
    /// `dayData` source whose deltas can undercount (e.g. StepSample).
    private var dayTotalFromData: Double {
        let r = activeDateRange
        return data.filter { r.contains($0.date) }.map(\.value).reduce(0, +)
    }

    private var headerValue: String {
        if let bucket = selectedBucket {
            return valueFormatter(bucket.display)
        }
        if selectedRange == .day {
            // Sum metrics: show day total from `data` (watch-accurate).
            // Range metrics: show the latest hourly bucket (e.g. recent HR).
            if useBarChart {
                return valueFormatter(dayTotalFromData)
            }
            return dayHourBuckets.last.map { valueFormatter($0.display) } ?? "--"
        }
        return buckets.last.map { valueFormatter($0.display) } ?? "--"
    }

    private var headerDate: Date? { selectedBucket?.date }

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

    private var xUnit: Calendar.Component {
        switch selectedRange {
        case .day:  return .hour
        case .year: return .month
        default:    return .day
        }
    }

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

    private var xDomain: ClosedRange<Date> { activeDateRange }

    private var calloutFormat: Date.FormatStyle {
        switch selectedRange {
        case .day:   return .dateTime.hour().minute()
        case .week:  return .dateTime.weekday(.abbreviated).month(.abbreviated).day()
        case .month: return .dateTime.month(.abbreviated).day()
        case .year:  return .dateTime.month(.wide)
        }
    }

    private var xAxisFormat: Date.FormatStyle {
        switch selectedRange {
        case .day:   return .dateTime.hour()
        case .year:  return .dateTime.month(.abbreviated)
        default:     return .dateTime.month(.abbreviated).day()
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
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(headerValue)
                        .font(.largeTitle).fontWeight(.bold).foregroundStyle(.primary)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.15), value: headerDate)
                    if showsTotalDiscrepancyHint {
                        Button {
                            showingTotalInfo = true
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("About this number")
                        .popover(isPresented: $showingTotalInfo,
                                 attachmentAnchor: .point(.bottom),
                                 arrowEdge: .top) {
                            totalInfoCallout
                                .presentationCompactAdaptation(.popover)
                        }
                    }
                }

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

    /// True when the day-total in the header comes from a different source than
    /// the bars below it (i.e. `data` is the watch-accurate rollup, `dayData`
    /// drives the bars). The (i) explains why bar sums may not match the total.
    private var showsTotalDiscrepancyHint: Bool {
        selectedRange == .day && useBarChart && dayData != nil && selectedBucket == nil
    }

    private var totalInfoCallout: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About this total")
                .font(.subheadline).fontWeight(.semibold)
            Text("The number above is the watch's end-of-day total for \(metricTitle.lowercased()). The bars below show per-record samples for finer time-of-day distribution — capture is sometimes patchy, so the bars may sum to less than the total.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: 280, alignment: .leading)
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
            if filteredData.isEmpty { emptyChart } else { barChart(for: dayChartBuckets).frame(height: 300) }
        } else if buckets.isEmpty {
            emptyChart
        } else {
            barChart(for: buckets).frame(height: 300)
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

    private func barChart(for data: [TrendBucket]) -> some View {
        let nonEmptyHighs = data.map(\.high).filter { $0 > 0 }
        let domain: ClosedRange<Double> = useBarChart
            ? ChartYDomain.zeroAnchored(for: nonEmptyHighs)
            : ChartYDomain.niceDomain(for: data.filter { $0.high > 0 }.flatMap { [$0.low, $0.high] })
        return Chart {
            ForEach(data) { bucket in
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
            AxisMarks(values: .automatic(desiredCount: selectedRange == .year ? 12 : 6)) { _ in
                AxisGridLine()
                AxisValueLabel(format: xAxisFormat)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let x = drag.location.x - geo[proxy.plotAreaFrame].origin.x
                            guard let date: Date = proxy.value(atX: x) else { return }
                            selectedBucket = data.min(by: {
                                abs(bucketCenterDate($0.date).timeIntervalSince(date)) <
                                abs(bucketCenterDate($1.date).timeIntervalSince(date))
                            }) ?? data.last
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
            VStack(alignment: .leading, spacing: 12) {
                Text("Statistics").font(.headline)
                Grid(alignment: .leadingFirstTextBaseline,
                     horizontalSpacing: 24,
                     verticalSpacing: 10) {
                    statRow("Mean",    valueFormatter(averageDisplay))
                    Divider()
                    statRow("Std Dev", valueFormatter(stdDevDisplay))
                    Divider()
                    statRow("Min",     valueFormatter(minDisplay))
                    Divider()
                    statRow("Max",     valueFormatter(maxDisplay))
                    Divider()
                    statRow("Count",   String(sampleCount))
                }
            }
            .padding()
            .background(card)
        }
    }

    @ViewBuilder
    private func statRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .font(.subheadline).fontWeight(.semibold)
                .monospacedDigit()
                .gridColumnAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.background)
            .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 2)
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
            metricTitle: "Heart Rate",
            metricUnit: "bpm",
            color: .red,
            icon: "heart.fill",
            data: sampleData,
            valueFormatter: { "\(Int($0)) bpm" }
        )
    }
}
