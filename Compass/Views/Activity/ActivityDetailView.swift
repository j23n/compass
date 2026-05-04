import SwiftUI
import SwiftData
import Charts
import MapKit
import CompassData
import CompassFIT

// MARK: - Chart metric selector

private enum ChartMetric: String, CaseIterable, Hashable {
    case heartRate = "Heart Rate"
    case elevation = "Elevation"
    case pace      = "Pace"
    case speed     = "Speed"
    case cadence   = "Cadence"

    var systemImage: String {
        switch self {
        case .heartRate: "heart.fill"
        case .elevation: "mountain.2.fill"
        case .pace:      "speedometer"
        case .speed:     "bicycle"
        case .cadence:   "figure.run"
        }
    }

    var color: Color {
        switch self {
        case .heartRate: .red
        case .elevation: .green
        case .pace:      .purple
        case .speed:     .blue
        case .cadence:   .orange
        }
    }

    func unit(for sport: Sport) -> String {
        switch self {
        case .heartRate: return "bpm"
        case .elevation: return "m"
        case .pace:
            return sport == .swimming ? "/100m" : (sport == .rowing ? "/500m" : "/km")
        case .speed:     return "km/h"
        case .cadence:
            switch sport {
            case .cycling, .mtb, .rowing, .kayaking: return "rpm"
            default: return "spm"
            }
        }
    }
}

// MARK: - Stat cell specs

private enum StatCellSpec {
    case distance, distanceMeters, duration
    case pace, paceSwim, paceRow, speed
    case avgHR, maxHR
    case ascentConditional, descentConditional
    case calories, cadenceConditional
}

private struct SportMetrics {
    let statCells: [StatCellSpec]
    let chartMetrics: [ChartMetric]
}

private func sportMetrics(for sport: Sport) -> SportMetrics {
    switch sport {
    case .running:
        return SportMetrics(
            statCells: [.distance, .pace, .avgHR, .maxHR, .ascentConditional, .descentConditional, .calories, .cadenceConditional, .duration],
            chartMetrics: [.heartRate, .elevation, .pace, .cadence]
        )
    case .cycling, .mtb:
        return SportMetrics(
            statCells: [.distance, .speed, .avgHR, .maxHR, .ascentConditional, .descentConditional, .calories, .duration],
            chartMetrics: [.heartRate, .elevation, .speed, .cadence]
        )
    case .swimming:
        return SportMetrics(
            statCells: [.distanceMeters, .paceSwim, .avgHR, .maxHR, .calories, .duration],
            chartMetrics: [.heartRate, .pace]
        )
    case .hiking:
        return SportMetrics(
            statCells: [.distance, .pace, .avgHR, .maxHR, .ascentConditional, .descentConditional, .calories, .duration],
            chartMetrics: [.heartRate, .elevation, .pace]
        )
    case .walking:
        return SportMetrics(
            statCells: [.distance, .pace, .avgHR, .maxHR, .calories, .duration],
            chartMetrics: [.heartRate, .pace]
        )
    case .rowing:
        return SportMetrics(
            statCells: [.distance, .paceRow, .avgHR, .maxHR, .calories, .cadenceConditional, .duration],
            chartMetrics: [.heartRate, .pace, .cadence]
        )
    case .kayaking:
        return SportMetrics(
            statCells: [.distance, .speed, .avgHR, .maxHR, .calories, .duration],
            chartMetrics: [.heartRate, .speed]
        )
    case .skiing:
        return SportMetrics(
            statCells: [.distance, .speed, .avgHR, .maxHR, .descentConditional, .calories, .duration],
            chartMetrics: [.heartRate, .elevation, .speed]
        )
    case .snowboarding:
        return SportMetrics(
            statCells: [.distance, .speed, .avgHR, .maxHR, .descentConditional, .calories, .duration],
            chartMetrics: [.heartRate, .elevation, .speed]
        )
    case .sup:
        return SportMetrics(
            statCells: [.distance, .speed, .avgHR, .maxHR, .calories, .duration],
            chartMetrics: [.heartRate, .speed]
        )
    case .climbing:
        return SportMetrics(
            statCells: [.duration, .avgHR, .maxHR, .ascentConditional, .calories],
            chartMetrics: [.heartRate, .elevation]
        )
    case .boating:
        return SportMetrics(
            statCells: [.distance, .speed, .duration],
            chartMetrics: [.speed]
        )
    case .strength:
        return SportMetrics(
            statCells: [.duration, .calories, .avgHR, .maxHR],
            chartMetrics: [.heartRate]
        )
    case .yoga:
        return SportMetrics(
            statCells: [.duration, .avgHR, .maxHR],
            chartMetrics: [.heartRate]
        )
    case .cardio:
        return SportMetrics(
            statCells: [.duration, .calories, .avgHR, .maxHR],
            chartMetrics: [.heartRate]
        )
    case .other:
        return SportMetrics(
            statCells: [.distance, .duration, .avgHR, .maxHR, .calories],
            chartMetrics: [.heartRate]
        )
    }
}

// MARK: - Section heading

private struct SectionHeading: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.title3).fontWeight(.semibold)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

// MARK: - Chart callout (matches TrendChartView style)

private struct ChartCallout: View {
    let value: String
    let unit: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value + " " + unit)
                .font(.caption).fontWeight(.bold)
                .foregroundStyle(.primary)
            Text(label)
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

// MARK: - Share sheet wrapper

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Detail view

struct ActivityDetailView: View {
    let activity: Activity

    @State private var selectedMetric: ChartMetric = .heartRate
    @State private var highlightedElapsed: TimeInterval? = nil
    @State private var highlightedCoordinate: CLLocationCoordinate2D? = nil
    @State private var shareItems: [Any] = []
    @State private var isSharePresented = false
    @State private var sortedTrackPoints: [TrackPoint] = []
    /// GPS-only elapsed/coord index, computed once on appear. Built per-render before
    /// caused the map dot to jump or stutter under continuous scrubbing.
    @State private var cachedElapsedIndex: [(elapsed: TimeInterval, coord: CLLocationCoordinate2D)] = []

    private var hasGPS: Bool {
        sortedTrackPoints.contains { $0.latitude != 0 || $0.longitude != 0 }
    }

    private var metrics: SportMetrics { sportMetrics(for: activity.sport) }

    // MARK: - Formatting

    private var durationString: String {
        let h = Int(activity.duration) / 3600
        let m = (Int(activity.duration) % 3600) / 60
        let s = Int(activity.duration) % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    private var distanceString: String { String(format: "%.2f", activity.distance / 1000.0) }
    private var distanceMetersString: String { String(format: "%.0f", activity.distance) }

    private var paceString: String {
        guard activity.distance > 0 else { return "--" }
        let secPerKm = activity.duration / (activity.distance / 1000.0)
        return String(format: "%d:%02d", Int(secPerKm) / 60, Int(secPerKm) % 60)
    }

    private var speedString: String {
        guard activity.duration > 0, activity.distance > 0 else { return "--" }
        let kmh = (activity.distance / 1000.0) / (activity.duration / 3600.0)
        return String(format: "%.1f", kmh)
    }

    private var swimPaceString: String {
        guard activity.distance > 0 else { return "--" }
        let secPer100m = activity.duration / (activity.distance / 100.0)
        return String(format: "%d:%02d", Int(secPer100m) / 60, Int(secPer100m) % 60)
    }

    private var rowPaceString: String {
        guard activity.distance > 0 else { return "--" }
        let secPer500m = activity.duration / (activity.distance / 500.0)
        return String(format: "%d:%02d", Int(secPer500m) / 60, Int(secPer500m) % 60)
    }

    private var caloriesString: String {
        guard let activeCalories = activity.activeCalories, activeCalories > 0 else { return "--" }
        return "\(Int(activeCalories))"
    }

    private var avgCadenceString: String {
        let cadences = sortedTrackPoints.compactMap { $0.cadence }.filter { $0 > 0 }
        guard !cadences.isEmpty else { return "--" }
        return "\(cadences.reduce(0, +) / cadences.count)"
    }

    private var hasCadenceData: Bool {
        sortedTrackPoints.contains { ($0.cadence ?? 0) > 0 }
    }

    // MARK: - Track-point data (timestamp-based, for chart interaction)

    private var elevationData: [(timestamp: Date, altitude: Double)] {
        sortedTrackPoints.compactMap { point in
            guard let alt = point.altitude else { return nil }
            return (timestamp: point.timestamp, altitude: alt)
        }
    }

    private var heartRateData: [(timestamp: Date, hr: Int)] {
        sortedTrackPoints.compactMap { point in
            guard let hr = point.heartRate else { return nil }
            return (timestamp: point.timestamp, hr: hr)
        }
    }

    private var speedOverTime: [(timestamp: Date, kmh: Double)] {
        sortedTrackPoints.compactMap { point in
            guard let speed = point.speed, speed > 0 else { return nil }
            return (timestamp: point.timestamp, kmh: speed * 3.6)
        }
    }

    private var paceOverTime: [(timestamp: Date, secPerKm: Double)] {
        sortedTrackPoints.compactMap { point in
            guard let speed = point.speed, speed > 0.5 else { return nil }
            return (timestamp: point.timestamp, secPerKm: 1000.0 / speed)
        }
    }

    private var cadenceOverTime: [(timestamp: Date, cadence: Int)] {
        sortedTrackPoints.compactMap { point in
            guard let c = point.cadence, c > 0 else { return nil }
            return (timestamp: point.timestamp, cadence: c)
        }
    }

    // MARK: - Elapsed-time chart data (x-axis as seconds from start)

    private func elapsed(_ date: Date) -> TimeInterval {
        date.timeIntervalSince(activity.startDate)
    }

    private var elapsedHRData: [(t: TimeInterval, v: Double)] {
        heartRateData.map { (elapsed($0.timestamp), Double($0.hr)) }
    }
    private var elapsedElevData: [(t: TimeInterval, v: Double)] {
        elevationData.map { (elapsed($0.timestamp), $0.altitude) }
    }
    private var elapsedPaceData: [(t: TimeInterval, v: Double)] {
        paceOverTime.map { (elapsed($0.timestamp), $0.secPerKm) }
    }
    private var elapsedSpeedData: [(t: TimeInterval, v: Double)] {
        speedOverTime.map { (elapsed($0.timestamp), $0.kmh) }
    }
    private var elapsedCadenceData: [(t: TimeInterval, v: Double)] {
        cadenceOverTime.map { (elapsed($0.timestamp), Double($0.cadence)) }
    }

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    private func formatCalloutTime(_ elapsed: TimeInterval) -> String {
        let wallTime = activity.startDate.addingTimeInterval(elapsed)
        let timeStr = wallTime.formatted(date: .omitted, time: .shortened)
        let elapsedStr = formatElapsed(elapsed)
        return "\(timeStr) · \(elapsedStr) in"
    }

    // MARK: - Available metrics (intersect sport allowlist with data presence)

    private func hasData(for metric: ChartMetric) -> Bool {
        switch metric {
        case .heartRate: return !heartRateData.isEmpty
        case .elevation: return !elevationData.isEmpty
        case .pace:      return !paceOverTime.isEmpty
        case .speed:     return !speedOverTime.isEmpty
        case .cadence:   return !cadenceOverTime.isEmpty
        }
    }

    private var availableMetrics: [ChartMetric] {
        metrics.chartMetrics.filter { hasData(for: $0) }
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                activityHeader

                SectionHeading("Stats")
                statsGrid

                if hasGPS {
                    SectionHeading("Route")
                    mapSection
                }

                if !availableMetrics.isEmpty {
                    SectionHeading("Charts")
                    chartSection
                }
            }
            .padding()
        }
        .navigationTitle(activity.sport.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: prepareAndShare) {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(activity.sourceFileName == nil && !hasGPS)
            }
        }
        .sheet(isPresented: $isSharePresented) {
            ShareSheet(items: shareItems)
                .presentationDetents([.medium, .large])
        }
        .onAppear {
            sortedTrackPoints = activity.trackPoints.sorted { $0.timestamp < $1.timestamp }
            cachedElapsedIndex = sortedTrackPoints
                .filter { $0.latitude != 0 || $0.longitude != 0 }
                .map { tp in
                    (
                        elapsed: tp.timestamp.timeIntervalSince(activity.startDate),
                        coord: CLLocationCoordinate2D(latitude: tp.latitude, longitude: tp.longitude)
                    )
                }
            if let first = availableMetrics.first {
                selectedMetric = first
            }
        }
    }

    // MARK: - Header

    private var activityHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: activity.sport.systemImage)
                .font(.title2)
                .foregroundStyle(activity.sport.color)
                .frame(width: 48, height: 48)
                .background(activity.sport.color.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(activity.sport.displayName)
                    .font(.title3).fontWeight(.semibold)
                Text(activity.startDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(durationString)
                    .font(.title3).fontWeight(.semibold).monospacedDigit()
                Text("duration")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(0.07), radius: 8, x: 0, y: 2)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
    }

    // MARK: - Map

    private var mapSection: some View {
        // Render size at 2x logical width for crispness on retina displays.
        // Cache key includes "_detail" so it doesn't collide with the row thumbnail.
        MapSnapshotView(
            trackPoints: sortedTrackPoints,
            size: CGSize(width: 800, height: 440),
            cacheKey: "activity_\(activity.id.uuidString)_detail",
            highlightCoordinate: highlightedCoordinate
        )
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
    }

    // MARK: - Stats grid (driven by per-sport matrix)

    private var statsGrid: some View {
        let cells = resolvedStatCells()
        return statCard {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                spacing: 8
            ) {
                ForEach(cells.indices, id: \.self) { i in
                    cells[i].view
                }
            }
        }
    }

    private struct ResolvedStat {
        let view: AnyView
    }

    private func resolvedStatCells() -> [ResolvedStat] {
        metrics.statCells.compactMap { spec in
            switch spec {
            case .distance:
                return ResolvedStat(view: AnyView(StatCell(title: "Distance", value: distanceString, unit: "km")))
            case .distanceMeters:
                return ResolvedStat(view: AnyView(StatCell(title: "Distance", value: distanceMetersString, unit: "m")))
            case .duration:
                return ResolvedStat(view: AnyView(StatCell(title: "Time", value: durationString)))
            case .pace:
                return ResolvedStat(view: AnyView(StatCell(title: "Pace", value: paceString, unit: "/km")))
            case .paceSwim:
                return ResolvedStat(view: AnyView(StatCell(title: "Pace", value: swimPaceString, unit: "/100m")))
            case .paceRow:
                return ResolvedStat(view: AnyView(StatCell(title: "Pace", value: rowPaceString, unit: "/500m")))
            case .speed:
                return ResolvedStat(view: AnyView(StatCell(title: "Speed", value: speedString, unit: "km/h")))
            case .avgHR:
                return ResolvedStat(view: AnyView(StatCell(title: "Avg HR", value: activity.avgHeartRate.map { "\($0)" } ?? "--", unit: "bpm")))
            case .maxHR:
                return ResolvedStat(view: AnyView(StatCell(title: "Max HR", value: activity.maxHeartRate.map { "\($0)" } ?? "--", unit: "bpm")))
            case .ascentConditional:
                guard let asc = activity.totalAscent, asc > 0 else { return nil }
                return ResolvedStat(view: AnyView(StatCell(title: "Ascent", value: "+\(Int(asc))", unit: "m")))
            case .descentConditional:
                guard let desc = activity.totalDescent, desc > 0 else { return nil }
                return ResolvedStat(view: AnyView(StatCell(title: "Descent", value: "-\(Int(desc))", unit: "m")))
            case .calories:
                return ResolvedStat(view: AnyView(StatCell(title: "Active Cal", value: caloriesString, unit: "kcal")))
            case .cadenceConditional:
                guard hasCadenceData else { return nil }
                let unit = ChartMetric.cadence.unit(for: activity.sport)
                return ResolvedStat(view: AnyView(StatCell(title: "Cadence", value: avgCadenceString, unit: unit)))
            }
        }
    }

    @ViewBuilder
    private func statCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding()
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.background)
                    .shadow(color: .black.opacity(0.07), radius: 8, x: 0, y: 2)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
    }

    // MARK: - Chart section

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Pills row
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(availableMetrics, id: \.self) { metric in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedMetric = metric
                                highlightedElapsed = nil
                                highlightedCoordinate = nil
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: metric.systemImage).font(.caption)
                                Text(metric.rawValue)
                                    .font(.subheadline)
                                    .fontWeight(selectedMetric == metric ? .semibold : .regular)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(selectedMetric == metric ? metric.color : Color(.systemGray5))
                            .foregroundStyle(selectedMetric == metric ? .white : .primary)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
            }

            Divider()

            // Chart body
            chartBody
                .frame(height: 200)
                .padding(.horizontal, 12).padding(.vertical, 12)
        }
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(0.07), radius: 8, x: 0, y: 2)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private var chartBody: some View {
        switch selectedMetric {
        case .heartRate:
            metricChart(data: elapsedHRData, color: .red) { "\(Int($0))" }
        case .elevation:
            metricChart(data: elapsedElevData, color: .green) { "\(Int($0))" }
        case .pace:
            metricChart(data: elapsedPaceData, color: .purple, reversed: true) {
                let m = Int($0) / 60; let s = Int($0) % 60
                return String(format: "%d:%02d", m, s)
            }
        case .speed:
            metricChart(data: elapsedSpeedData, color: .blue) { String(format: "%.1f", $0) }
        case .cadence:
            metricChart(data: elapsedCadenceData, color: .orange) { "\(Int($0))" }
        }
    }

    @ViewBuilder
    private func metricChart(
        data: [(t: TimeInterval, v: Double)],
        color: Color,
        reversed: Bool = false,
        yFormat: @escaping (Double) -> String
    ) -> some View {
        if reversed {
            baseChart(data: data, color: color, reversed: true, yFormat: yFormat)
                .chartYScale(domain: .automatic(includesZero: false, reversed: true))
        } else {
            baseChart(data: data, color: color, reversed: false, yFormat: yFormat)
                .chartYScale(domain: ChartYDomain.niceDomain(for: data.map(\.v)))
        }
    }

    private func strideInterval(_ duration: TimeInterval) -> Double {
        switch duration {
        case ..<600:   return 60
        case ..<3600:  return 300
        case ..<7200:  return 600
        default:       return 1800
        }
    }

    private func baseChart(
        data: [(t: TimeInterval, v: Double)],
        color: Color,
        reversed: Bool,
        yFormat: @escaping (Double) -> String
    ) -> some View {
        // Anchor the area fill at the visible chart floor so the gradient never
        // overflows past the x-axis when the y-domain doesn't include 0.
        // For reversed scales (pace), the visual floor is the max data value.
        let values = data.map(\.v)
        let baseline = reversed ? (values.max() ?? 0) : (values.min() ?? 0)
        return Chart {
            ForEach(Array(data.enumerated()), id: \.offset) { _, point in
                AreaMark(
                    x: .value("T", point.t),
                    yStart: .value("Base", baseline),
                    yEnd: .value("V", point.v)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [color.opacity(0.35), color.opacity(0.0)],
                        startPoint: reversed ? .bottom : .top,
                        endPoint:   reversed ? .top    : .bottom
                    )
                )
                .interpolationMethod(.catmullRom)
                LineMark(x: .value("T", point.t), y: .value("V", point.v))
                    .foregroundStyle(color)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }

            if let hl = highlightedElapsed, let nearest = nearestPoint(in: data, elapsed: hl) {
                RuleMark(x: .value("T", nearest.t))
                    .foregroundStyle(.primary.opacity(0.25))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .center, spacing: 4) {
                        ChartCallout(
                            value: yFormat(nearest.v),
                            unit: selectedMetric.unit(for: activity.sport),
                            label: formatCalloutTime(nearest.t)
                        )
                    }
                PointMark(x: .value("T", nearest.t), y: .value("V", nearest.v))
                    .foregroundStyle(color)
                    .symbolSize(60)
            }
        }
        .chartXScale(domain: 0...max(activity.duration, 1))
        .chartXAxis {
            AxisMarks(values: .stride(by: strideInterval(activity.duration))) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(formatElapsed(v)).font(.caption2)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(yFormat(v)).font(.caption2)
                    }
                }
            }
        }
        .chartYAxisLabel(selectedMetric.unit(for: activity.sport), position: .leading)
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                let x = drag.location.x - geo[proxy.plotAreaFrame].origin.x
                                if let t: TimeInterval = proxy.value(atX: x) {
                                    updateHighlight(elapsed: t)
                                }
                            }
                            // Keep highlight visible after gesture ends (matches map dot behavior).
                    )
            }
        }
    }

    private func nearestPoint(
        in data: [(t: TimeInterval, v: Double)],
        elapsed: TimeInterval
    ) -> (t: TimeInterval, v: Double)? {
        data.min(by: { abs($0.t - elapsed) < abs($1.t - elapsed) })
    }

    /// Maximum gap (in seconds) between the requested elapsed time and the nearest
    /// GPS point before we drop the map dot. Beyond this, the closest GPS sample is
    /// usually so far away in time that highlighting it on the map is misleading
    /// (this happens at the start of a hike before the first satellite lock, or
    /// during long tunnels / canopy gaps).
    private static let maxGPSGapSeconds: TimeInterval = 30

    private func coordAtElapsed(_ seconds: TimeInterval) -> CLLocationCoordinate2D? {
        let index = cachedElapsedIndex
        var lo = 0, hi = index.count - 1
        guard hi >= 0 else { return nil }
        while lo < hi {
            let mid = (lo + hi) / 2
            if index[mid].elapsed < seconds { lo = mid + 1 } else { hi = mid }
        }
        let pick: Int
        if lo == 0 {
            pick = 0
        } else {
            let prevDelta = abs(index[lo - 1].elapsed - seconds)
            let curDelta  = abs(index[lo].elapsed - seconds)
            pick = prevDelta < curDelta ? lo - 1 : lo
        }
        guard abs(index[pick].elapsed - seconds) <= Self.maxGPSGapSeconds else { return nil }
        return index[pick].coord
    }

    // MARK: - Chart interaction

    private func updateHighlight(elapsed: TimeInterval) {
        let clamped = max(0, min(elapsed, activity.duration))
        highlightedElapsed = clamped
        guard hasGPS else { return }
        highlightedCoordinate = coordAtElapsed(clamped)
    }

    // MARK: - Share

    private func prepareAndShare() {
        var items: [Any] = []

        if let fileName = activity.sourceFileName {
            let fitURL = FITFileStore.shared.directory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: fitURL.path) {
                items.append(fitURL)
            }
        }

        if hasGPS, let gpxData = ActivityGPXExporter.export(activity: activity) {
            let dateStr = activity.startDate.formatted(.iso8601)
                .replacingOccurrences(of: ":", with: "-")
                .replacingOccurrences(of: "T", with: "_")
                .prefix(19)
            let filename = "\(activity.sport.displayName)_\(dateStr).gpx"
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            try? gpxData.write(to: tempURL)
            items.append(tempURL)
        }

        guard !items.isEmpty else { return }
        shareItems = items
        isSharePresented = true
    }
}

// MARK: - Preview

#Preview {
    let activity = Activity(
        startDate: Date().addingTimeInterval(-3600),
        endDate: Date(),
        sport: .running,
        distance: 5230,
        duration: 1725,
        activeCalories: 420,
        avgHeartRate: 156,
        maxHeartRate: 178,
        totalAscent: 82,
        totalDescent: 79
    )

    NavigationStack {
        ActivityDetailView(activity: activity)
    }
    .modelContainer(for: [Activity.self, TrackPoint.self], inMemory: true)
}
