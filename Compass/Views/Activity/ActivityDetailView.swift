import SwiftUI
import SwiftData
import Charts
import MapKit
import CompassData

/// Activity detail: Apple Maps route hero, sport-specific stats, and time-series charts.
struct ActivityDetailView: View {
    let activity: Activity

    private var sortedTrackPoints: [TrackPoint] {
        activity.trackPoints.sorted { $0.timestamp < $1.timestamp }
    }

    private var hasGPS: Bool {
        sortedTrackPoints.contains { $0.latitude != 0 || $0.longitude != 0 }
    }

    // MARK: - Formatting helpers

    private var distanceString: String { String(format: "%.2f", activity.distance / 1000.0) }

    private var durationString: String {
        let h = Int(activity.duration) / 3600
        let m = (Int(activity.duration) % 3600) / 60
        let s = Int(activity.duration) % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

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

    /// Swim pace in min:ss per 100 m
    private var swimPaceString: String {
        guard activity.distance > 0 else { return "--" }
        let secPer100m = activity.duration / (activity.distance / 100.0)
        return String(format: "%d:%02d", Int(secPer100m) / 60, Int(secPer100m) % 60)
    }

    private var caloriesString: String {
        activity.totalCalories > 0 ? "\(Int(activity.totalCalories))" : "--"
    }

    // MARK: - Track-point data

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

    /// Speed in km/h over time
    private var speedOverTime: [(timestamp: Date, kmh: Double)] {
        sortedTrackPoints.compactMap { point in
            guard let speed = point.speed, speed > 0 else { return nil }
            return (timestamp: point.timestamp, kmh: speed * 3.6)
        }
    }

    /// Pace in seconds/km over time (filtered to plausible running speeds)
    private var paceOverTime: [(timestamp: Date, secPerKm: Double)] {
        sortedTrackPoints.compactMap { point in
            guard let speed = point.speed, speed > 0.5 else { return nil }
            return (timestamp: point.timestamp, secPerKm: 1000.0 / speed)
        }
    }

    private func formatPace(_ secPerKm: Double) -> String {
        let m = Int(secPerKm) / 60
        let s = Int(secPerKm) % 60
        return String(format: "%d:%02d /km", m, s)
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                mapSection
                statsGrid
                if !elevationData.isEmpty { elevationSection }
                if !heartRateData.isEmpty { heartRateSection }
                if showsPaceChart && !paceOverTime.isEmpty { paceSection }
                if showsSpeedChart && !speedOverTime.isEmpty { speedSection }
            }
            .padding()
        }
        .navigationTitle(activity.sport.displayName)
        .navigationBarTitleDisplayMode(.large)
    }

    private var showsPaceChart: Bool {
        [.running, .hiking, .walking].contains(activity.sport)
    }

    private var showsSpeedChart: Bool {
        activity.sport == .cycling
    }

    // MARK: - Map

    @ViewBuilder
    private var mapSection: some View {
        ZStack {
            if hasGPS {
                MapRouteView(trackPoints: sortedTrackPoints)
            } else {
                noGPSPlaceholder
            }
        }
        .frame(height: 260)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
    }

    private var noGPSPlaceholder: some View {
        ZStack {
            Color(.systemGray5)
            VStack(spacing: 8) {
                Image(systemName: "location.slash")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No GPS Data")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
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
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                StatCell(title: "Distance", value: distanceString, unit: "km")
                StatCell(title: "Time", value: durationString)
            }
            GridRow {
                StatCell(title: "Pace", value: paceString, unit: "/km")
                StatCell(title: "Avg HR", value: activity.avgHeartRate.map { "\($0)" } ?? "--", unit: "bpm")
            }
            if activity.totalAscent != nil || activity.totalDescent != nil {
                GridRow {
                    StatCell(title: "Ascent", value: activity.totalAscent.map { "+\(Int($0))" } ?? "--", unit: "m")
                    StatCell(title: "Descent", value: activity.totalDescent.map { "-\(Int($0))" } ?? "--", unit: "m")
                }
            }
            GridRow {
                StatCell(title: "Max HR", value: activity.maxHeartRate.map { "\($0)" } ?? "--", unit: "bpm")
                StatCell(title: "Calories", value: caloriesString, unit: "kcal")
            }
        }
    }

    private var cyclingStats: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                StatCell(title: "Distance", value: distanceString, unit: "km")
                StatCell(title: "Time", value: durationString)
            }
            GridRow {
                StatCell(title: "Speed", value: speedString, unit: "km/h")
                StatCell(title: "Avg HR", value: activity.avgHeartRate.map { "\($0)" } ?? "--", unit: "bpm")
            }
            GridRow {
                StatCell(title: "Max HR", value: activity.maxHeartRate.map { "\($0)" } ?? "--", unit: "bpm")
                StatCell(title: "Calories", value: caloriesString, unit: "kcal")
            }
        }
    }

    private var swimmingStats: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                StatCell(title: "Distance", value: String(format: "%.0f", activity.distance), unit: "m")
                StatCell(title: "Time", value: durationString)
            }
            GridRow {
                StatCell(title: "Pace", value: swimPaceString, unit: "/100m")
                StatCell(title: "Avg HR", value: activity.avgHeartRate.map { "\($0)" } ?? "--", unit: "bpm")
            }
            GridRow {
                StatCell(title: "Max HR", value: activity.maxHeartRate.map { "\($0)" } ?? "--", unit: "bpm")
                StatCell(title: "Calories", value: caloriesString, unit: "kcal")
            }
        }
    }

    private var strengthStats: some View {
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

    private var defaultStats: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                StatCell(title: "Distance", value: distanceString, unit: "km")
                StatCell(title: "Time", value: durationString)
            }
            GridRow {
                StatCell(title: "Pace", value: paceString, unit: "/km")
                StatCell(title: "Avg HR", value: activity.avgHeartRate.map { "\($0)" } ?? "--", unit: "bpm")
            }
            GridRow {
                StatCell(title: "Max HR", value: activity.maxHeartRate.map { "\($0)" } ?? "--", unit: "bpm")
                StatCell(title: "Calories", value: caloriesString, unit: "kcal")
            }
        }
    }

    // MARK: - Elevation

    @ViewBuilder
    private var elevationSection: some View {
        chartCard {
            HStack(spacing: 8) {
                Image(systemName: "mountain.2.fill").foregroundStyle(.green).font(.subheadline)
                Text("Elevation").font(.headline)
                Spacer()
                if let ascent = activity.totalAscent {
                    Text("+\(Int(ascent))m").font(.caption).fontWeight(.medium).foregroundStyle(.green)
                }
                if let descent = activity.totalDescent {
                    Text("-\(Int(descent))m").font(.caption).fontWeight(.medium).foregroundStyle(.red)
                }
            }

            Chart(elevationData, id: \.timestamp) { point in
                AreaMark(x: .value("Time", point.timestamp), y: .value("Altitude", point.altitude))
                    .foregroundStyle(LinearGradient(
                        colors: [Color.green.opacity(0.35), Color.green.opacity(0.05)],
                        startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("Time", point.timestamp), y: .value("Altitude", point.altitude))
                    .foregroundStyle(.green)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text("\(Int(v))m").font(.caption2) }
                    }
                }
            }
            .frame(height: 140)
        }
    }

    // MARK: - Heart Rate

    @ViewBuilder
    private var heartRateSection: some View {
        let avgHR = heartRateData.isEmpty ? 0 : heartRateData.reduce(0) { $0 + $1.hr } / heartRateData.count

        chartCard {
            HStack(spacing: 8) {
                Image(systemName: "heart.fill").foregroundStyle(.red).font(.subheadline)
                Text("Heart Rate").font(.headline)
                Spacer()
                if avgHR > 0 {
                    Text("Avg \(avgHR) bpm").font(.caption).fontWeight(.medium).foregroundStyle(.red)
                }
                if let max = activity.maxHeartRate {
                    Text("Max \(max) bpm").font(.caption).fontWeight(.medium).foregroundStyle(.red)
                }
            }

            Chart(heartRateData, id: \.timestamp) { point in
                AreaMark(x: .value("Time", point.timestamp), y: .value("HR", point.hr))
                    .foregroundStyle(LinearGradient(
                        colors: [Color.red.opacity(0.25), Color.red.opacity(0.0)],
                        startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("Time", point.timestamp), y: .value("HR", point.hr))
                    .foregroundStyle(.red)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
            .frame(height: 140)
        }
    }

    // MARK: - Pace chart (running / hiking / walking)

    @ViewBuilder
    private var paceSection: some View {
        chartCard {
            HStack(spacing: 8) {
                Image(systemName: "speedometer").foregroundStyle(.purple).font(.subheadline)
                Text("Pace").font(.headline)
                Spacer()
                Text("/km").font(.caption).foregroundStyle(.secondary)
            }

            Chart(paceOverTime, id: \.timestamp) { point in
                AreaMark(x: .value("Time", point.timestamp), y: .value("Pace", point.secPerKm))
                    .foregroundStyle(LinearGradient(
                        colors: [Color.purple.opacity(0.3), Color.purple.opacity(0.0)],
                        startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("Time", point.timestamp), y: .value("Pace", point.secPerKm))
                    .foregroundStyle(.purple)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(String(format: "%d:%02d", Int(v) / 60, Int(v) % 60))
                                .font(.caption2)
                        }
                    }
                }
            }
            // Invert axis: lower pace number (faster) should appear at the top
            .chartYScale(domain: .automatic(includesZero: false, reversed: true))
            .frame(height: 140)
        }
    }

    // MARK: - Speed chart (cycling)

    @ViewBuilder
    private var speedSection: some View {
        chartCard {
            HStack(spacing: 8) {
                Image(systemName: "bicycle").foregroundStyle(.blue).font(.subheadline)
                Text("Speed").font(.headline)
                Spacer()
                Text("km/h").font(.caption).foregroundStyle(.secondary)
            }

            Chart(speedOverTime, id: \.timestamp) { point in
                AreaMark(x: .value("Time", point.timestamp), y: .value("Speed", point.kmh))
                    .foregroundStyle(LinearGradient(
                        colors: [Color.blue.opacity(0.3), Color.blue.opacity(0.0)],
                        startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("Time", point.timestamp), y: .value("Speed", point.kmh))
                    .foregroundStyle(.blue)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
            .frame(height: 140)
        }
    }

    // MARK: - Shared card shell

    @ViewBuilder
    private func chartCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
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
