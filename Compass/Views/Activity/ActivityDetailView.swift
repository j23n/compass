import SwiftUI
import SwiftData
import Charts
import CompassData

/// Activity detail screen showing map, stats, elevation, and heart rate.
struct ActivityDetailView: View {
    let activity: Activity

    private var sortedTrackPoints: [TrackPoint] {
        activity.trackPoints.sorted { $0.timestamp < $1.timestamp }
    }

    private var paceString: String {
        guard activity.distance > 0 else { return "--" }
        let paceSecondsPerKm = activity.duration / (activity.distance / 1000.0)
        let minutes = Int(paceSecondsPerKm) / 60
        let seconds = Int(paceSecondsPerKm) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var distanceString: String {
        let km = activity.distance / 1000.0
        return String(format: "%.2f", km)
    }

    private var durationString: String {
        let hours = Int(activity.duration) / 3600
        let minutes = (Int(activity.duration) % 3600) / 60
        let seconds = Int(activity.duration) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var elevationData: [(index: Int, altitude: Double)] {
        sortedTrackPoints.enumerated().compactMap { index, point in
            guard let alt = point.altitude else { return nil }
            return (index: index, altitude: alt)
        }
    }

    private var heartRateData: [(timestamp: Date, hr: Int)] {
        sortedTrackPoints.compactMap { point in
            guard let hr = point.heartRate else { return nil }
            return (timestamp: point.timestamp, hr: hr)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                // Map placeholder
                mapPlaceholder

                // Hero stats grid
                statsGrid

                // Elevation profile
                if !elevationData.isEmpty {
                    elevationSection
                }

                // Heart rate over time
                if !heartRateData.isEmpty {
                    heartRateSection
                }
            }
            .padding()
        }
        .navigationTitle(activity.sport.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Map Placeholder

    @ViewBuilder
    private var mapPlaceholder: some View {
        // TODO: Replace with MapLibre integration once SPM dependency is resolved.
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.systemGray5))

            VStack(spacing: 8) {
                Image(systemName: "map")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)

                Text("Map View")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Text("Route visualization coming soon")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(minHeight: 280)
        .frame(maxHeight: 360)
    }

    // MARK: - Stats Grid

    @ViewBuilder
    private var statsGrid: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                StatCell(
                    title: "Distance",
                    value: distanceString,
                    unit: "km"
                )
                StatCell(
                    title: "Time",
                    value: durationString
                )
            }
            GridRow {
                StatCell(
                    title: "Pace",
                    value: paceString,
                    unit: "/km"
                )
                StatCell(
                    title: "Avg HR",
                    value: activity.avgHeartRate.map { "\($0)" } ?? "--",
                    unit: "bpm"
                )
            }
        }
    }

    // MARK: - Elevation Profile

    @ViewBuilder
    private var elevationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "mountain.2.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline)

                Text("Elevation")
                    .font(.headline)

                Spacer()

                if let ascent = activity.totalAscent {
                    Text("+\(Int(ascent))m")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .fontWeight(.medium)
                }
                if let descent = activity.totalDescent {
                    Text("-\(Int(descent))m")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fontWeight(.medium)
                }
            }

            Chart(elevationData, id: \.index) { point in
                AreaMark(
                    x: .value("Point", point.index),
                    y: .value("Altitude", point.altitude)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.green.opacity(0.3), Color.green.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("Point", point.index),
                    y: .value("Altitude", point.altitude)
                )
                .foregroundStyle(.green)
                .interpolationMethod(.catmullRom)
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text("\(Int(v))m")
                                .font(.caption2)
                        }
                    }
                }
            }
            .frame(height: 150)
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

    // MARK: - Heart Rate Chart

    @ViewBuilder
    private var heartRateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.red)
                    .font(.subheadline)

                Text("Heart Rate")
                    .font(.headline)

                Spacer()

                if let max = activity.maxHeartRate {
                    Text("Max \(max) bpm")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fontWeight(.medium)
                }
            }

            Chart(heartRateData, id: \.timestamp) { point in
                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("HR", point.hr)
                )
                .foregroundStyle(.red)
                .interpolationMethod(.catmullRom)
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
            .frame(height: 150)
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
