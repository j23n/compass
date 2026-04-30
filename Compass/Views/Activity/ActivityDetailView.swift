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

    var systemImage: String {
        switch self {
        case .heartRate: "heart.fill"
        case .elevation: "mountain.2.fill"
        case .pace:      "speedometer"
        case .speed:     "bicycle"
        }
    }

    var color: Color {
        switch self {
        case .heartRate: .red
        case .elevation: .green
        case .pace:      .purple
        case .speed:     .blue
        }
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

    private var sortedTrackPoints: [TrackPoint] {
        activity.trackPoints.sorted { $0.timestamp < $1.timestamp }
    }

    private var hasGPS: Bool {
        sortedTrackPoints.contains { $0.latitude != 0 || $0.longitude != 0 }
    }

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

    private var caloriesString: String {
        activity.totalCalories > 0 ? "\(Int(activity.totalCalories))" : "--"
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

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    // MARK: - Available metrics

    private var showsPaceChart: Bool { [.running, .hiking, .walking].contains(activity.sport) }
    private var showsSpeedChart: Bool { activity.sport == .cycling }

    private var availableMetrics: [ChartMetric] {
        var metrics: [ChartMetric] = []
        if !heartRateData.isEmpty  { metrics.append(.heartRate) }
        if !elevationData.isEmpty  { metrics.append(.elevation) }
        if showsPaceChart  && !paceOverTime.isEmpty  { metrics.append(.pace) }
        if showsSpeedChart && !speedOverTime.isEmpty { metrics.append(.speed) }
        return metrics
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                activityHeader
                if hasGPS {
                    mapSection
                }
                statsGrid
                if !availableMetrics.isEmpty {
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
        MapRouteView(
            trackPoints: sortedTrackPoints,
            highlightCoordinate: highlightedCoordinate
        )
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
    }

    // MARK: - Stats grid (sport-specific)

    @ViewBuilder
    private var statsGrid: some View {
        switch activity.sport {
        case .running, .hiking:
            runningHikingStats
        case .cycling:
            cyclingStats
        case .swimming:
            swimmingStats
        case .strength, .yoga:
            strengthStats
        default:
            defaultStats
        }
    }

    private var runningHikingStats: some View {
        statCard {
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    StatCell(title: "Distance", value: distanceString, unit: "km")
                    StatCell(title: "Pace", value: paceString, unit: "/km")
                }
                GridRow {
                    StatCell(title: "Avg HR", value: activity.avgHeartRate.map { "\($0)" } ?? "--", unit: "bpm")
                    StatCell(title: "Max HR", value: activity.maxHeartRate.map { "\($0)" } ?? "--", unit: "bpm")
                }
                if activity.totalAscent != nil || activity.totalDescent != nil {
                    GridRow {
                        StatCell(title: "Ascent", value: activity.totalAscent.map { "+\(Int($0))" } ?? "--", unit: "m")
                        StatCell(title: "Descent", value: activity.totalDescent.map { "-\(Int($0))" } ?? "--", unit: "m")
                    }
                }
                GridRow {
                    StatCell(title: "Calories", value: caloriesString, unit: "kcal")
                    StatCell(title: "Time", value: durationString)
                }
            }
        }
    }

    private var cyclingStats: some View {
        statCard {
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    StatCell(title: "Distance", value: distanceString, unit: "km")
                    StatCell(title: "Speed", value: speedString, unit: "km/h")
                }
                GridRow {
                    StatCell(title: "Avg HR", value: activity.avgHeartRate.map { "\($0)" } ?? "--", unit: "bpm")
                    StatCell(title: "Max HR", value: activity.maxHeartRate.map { "\($0)" } ?? "--", unit: "bpm")
                }
                GridRow {
                    StatCell(title: "Calories", value: caloriesString, unit: "kcal")
                    StatCell(title: "Time", value: durationString)
                }
            }
        }
    }

    private var swimmingStats: some View {
        statCard {
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    StatCell(title: "Distance", value: String(format: "%.0f", activity.distance), unit: "m")
                    StatCell(title: "Pace", value: swimPaceString, unit: "/100m")
                }
                GridRow {
                    StatCell(title: "Avg HR", value: activity.avgHeartRate.map { "\($0)" } ?? "--", unit: "bpm")
                    StatCell(title: "Max HR", value: activity.maxHeartRate.map { "\($0)" } ?? "--", unit: "bpm")
                }
                GridRow {
                    StatCell(title: "Calories", value: caloriesString, unit: "kcal")
                    StatCell(title: "Time", value: durationString)
                }
            }
        }
    }

    private var strengthStats: some View {
        statCard {
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    StatCell(title: "Time", value: durationString)
                    StatCell(title: "Calories", value: caloriesString, unit: "kcal")
                }
                GridRow {
                    StatCell(title: "Avg HR", value: activity.avgHeartRate.map { "\($0)" } ?? "--", unit: "bpm")
                    StatCell(title: "Max HR", value: activity.maxHeartRate.map { "\($0)" } ?? "--", unit: "bpm")
                }
            }
        }
    }

    private var defaultStats: some View {
        statCard {
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    StatCell(title: "Distance", value: distanceString, unit: "km")
                    StatCell(title: "Pace", value: paceString, unit: "/km")
                }
                GridRow {
                    StatCell(title: "Avg HR", value: activity.avgHeartRate.map { "\($0)" } ?? "--", unit: "bpm")
                    StatCell(title: "Max HR", value: activity.maxHeartRate.map { "\($0)" } ?? "--", unit: "bpm")
                }
                GridRow {
                    StatCell(title: "Calories", value: caloriesString, unit: "kcal")
                    StatCell(title: "Time", value: durationString)
                }
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
                .frame(height: 180)
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
            metricChart(data: elapsedHRData, color: .red) {
                "\(Int($0))"
            }
        case .elevation:
            metricChart(data: elapsedElevData, color: .green) {
                "\(Int($0))m"
            }
        case .pace:
            metricChart(data: elapsedPaceData, color: .purple, reversed: true) {
                let m = Int($0) / 60; let s = Int($0) % 60
                return String(format: "%d:%02d", m, s)
            }
        case .speed:
            metricChart(data: elapsedSpeedData, color: .blue) {
                String(format: "%.0f", $0)
            }
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
            baseChart(data: data, color: color, yFormat: yFormat)
                .chartYScale(domain: .automatic(includesZero: false, reversed: true))
        } else {
            baseChart(data: data, color: color, yFormat: yFormat)
        }
    }

    private func baseChart(
        data: [(t: TimeInterval, v: Double)],
        color: Color,
        yFormat: @escaping (Double) -> String
    ) -> some View {
        Chart(Array(data.enumerated()), id: \.offset) { _, point in
            AreaMark(x: .value("T", point.t), y: .value("V", point.v))
                .foregroundStyle(
                    LinearGradient(
                        colors: [color.opacity(0.35), color.opacity(0.0)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)
            LineMark(x: .value("T", point.t), y: .value("V", point.v))
                .foregroundStyle(color)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2))
            if let hl = highlightedElapsed {
                RuleMark(x: .value("T", hl))
                    .foregroundStyle(.primary.opacity(0.25))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(TimeInterval.self) {
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
        .chartLegend(.hidden)
        .overlay(alignment: .topTrailing) {
            if let hl = highlightedElapsed, let label = highlightLabel(data: data, elapsed: hl, format: yFormat) {
                Text(label)
                    .font(.caption).fontWeight(.semibold).monospacedDigit()
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .padding(4)
                    .transition(.opacity)
            }
        }
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
                            .onEnded { _ in
                                highlightedElapsed = nil
                                highlightedCoordinate = nil
                            }
                    )
            }
        }
    }

    private func highlightLabel(
        data: [(t: TimeInterval, v: Double)],
        elapsed: TimeInterval,
        format: (Double) -> String
    ) -> String? {
        guard let nearest = data.min(by: { abs($0.t - elapsed) < abs($1.t - elapsed) }) else { return nil }
        return format(nearest.v)
    }

    // MARK: - Chart interaction

    private func updateHighlight(elapsed: TimeInterval) {
        let clamped = max(0, min(elapsed, activity.duration))
        highlightedElapsed = clamped

        guard hasGPS else { return }
        let targetDate = activity.startDate.addingTimeInterval(clamped)
        let nearest = sortedTrackPoints
            .filter { $0.latitude != 0 || $0.longitude != 0 }
            .min { abs($0.timestamp.timeIntervalSince(targetDate)) < abs($1.timestamp.timeIntervalSince(targetDate)) }
        if let pt = nearest {
            highlightedCoordinate = CLLocationCoordinate2D(latitude: pt.latitude, longitude: pt.longitude)
        }
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
        totalCalories: 420,
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
