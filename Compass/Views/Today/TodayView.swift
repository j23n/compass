import SwiftUI
import SwiftData
import Charts
import CompassData
import CompassBLE

/// The main Today tab -- a vertically scrolling dashboard.
struct TodayView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncCoordinator.self) private var syncCoordinator

    @Query(sort: \ConnectedDevice.name)
    private var connectedDevices: [ConnectedDevice]

    @Query(sort: \Activity.startDate, order: .reverse)
    private var allActivities: [Activity]

    @Query(sort: \SleepSession.endDate, order: .reverse)
    private var allSleepSessions: [SleepSession]

    @Query(sort: \HeartRateSample.timestamp)
    private var allHeartRateSamples: [HeartRateSample]

    @Query(sort: \BodyBatterySample.timestamp)
    private var allBodyBattery: [BodyBatterySample]

    @Query(sort: \StressSample.timestamp)
    private var allStress: [StressSample]

    @Query(sort: \StepCount.date)
    private var allSteps: [StepCount]

    @State private var showingSettings = false

    // MARK: - Computed Data

    private var startOfToday: Date {
        Calendar.current.startOfDay(for: Date())
    }

    private var hasDevice: Bool {
        !connectedDevices.isEmpty
    }

    private var todayActivities: [Activity] {
        let start = startOfToday
        return allActivities.filter { $0.startDate >= start }
    }

    private var lastSleep: SleepSession? {
        allSleepSessions.first
    }

    private var todayRestingHR: [HeartRateSample] {
        let start = startOfToday
        return allHeartRateSamples.filter {
            $0.timestamp >= start && $0.context == .resting
        }
    }

    private var currentRestingHR: Int? {
        todayRestingHR.min(by: { $0.bpm < $1.bpm })?.bpm
    }

    private var restingHRSparkline: [Double] {
        todayRestingHR.suffix(20).map { Double($0.bpm) }
    }

    private var todayBodyBatterySamples: [BodyBatterySample] {
        let start = startOfToday
        return allBodyBattery.filter { $0.timestamp >= start }
    }

    private var currentBodyBattery: Int {
        todayBodyBatterySamples.last?.level ?? 0
    }

    private var todayStressSamples: [StressSample] {
        let start = startOfToday
        return allStress.filter { $0.timestamp >= start }
    }

    private var currentStress: Int {
        todayStressSamples.last?.stressScore ?? 0
    }

    private var todayStepCounts: [StepCount] {
        let start = startOfToday
        return allSteps.filter { $0.date >= start }
    }

    private var totalActivityMinutes: Int {
        todayStepCounts.reduce(0) { $0 + $1.intensityMinutes }
    }

    private var sleepHours: Double {
        guard let sleep = lastSleep else { return 0 }
        return sleep.endDate.timeIntervalSince(sleep.startDate) / 3600.0
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if hasDevice {
                    dashboardContent
                } else {
                    emptyStateView
                }
            }
            .navigationTitle("Today")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        AppLogger.ui.debug("Settings button tapped from TodayView")
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .onAppear {
                AppLogger.ui.debug("TodayView appeared — hasDevice: \(self.hasDevice), activities: \(self.allActivities.count), sleep: \(self.allSleepSessions.count), HR samples: \(self.allHeartRateSamples.count)")
            }
        }
    }

    // MARK: - Dashboard Content

    @ViewBuilder
    private var dashboardContent: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                heroSection
                heartRateSection
                sleepSection
                activitiesSection
                bodyBatterySection
                stressSection
            }
            .padding()
        }
        .refreshable {
            AppLogger.ui.debug("Pull-to-refresh triggered")
            await syncCoordinator.sync(context: modelContext)
        }
    }

    // MARK: - Hero Section

    @ViewBuilder
    private var heroSection: some View {
        RingsView(
            activityMinutes: totalActivityMinutes,
            activityGoal: 60,
            sleepHours: sleepHours,
            sleepGoal: 8.0,
            bodyBattery: currentBodyBattery,
            stressLevel: currentStress
        )
        .padding(.bottom, 8)
    }

    // MARK: - Heart Rate

    @ViewBuilder
    private var heartRateSection: some View {
        if let rhr = currentRestingHR {
            MetricCard(
                title: "Resting Heart Rate",
                value: "\(rhr)",
                unit: "bpm",
                color: .red,
                icon: "heart.fill",
                sparklineData: restingHRSparkline
            )
        }
    }

    // MARK: - Sleep

    @ViewBuilder
    private var sleepSection: some View {
        if let sleep = lastSleep {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "bed.double.fill")
                        .foregroundStyle(.purple)
                        .font(.subheadline)

                    Text("Last Night's Sleep")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer()

                    if let score = sleep.score {
                        Text("Score: \(score)")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.purple)
                    }
                }

                SleepStageBar(stages: sleep.stages)
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

    // MARK: - Activities

    @ViewBuilder
    private var activitiesSection: some View {
        if !todayActivities.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Activities")
                    .font(.headline)
                    .padding(.horizontal, 4)

                ForEach(todayActivities) { activity in
                    NavigationLink(destination: ActivityDetailView(activity: activity)) {
                        activityRow(activity)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func activityRow(_ activity: Activity) -> some View {
        HStack(spacing: 12) {
            Image(systemName: activity.sport.systemImage)
                .font(.title3)
                .foregroundStyle(.green)
                .frame(width: 36, height: 36)
                .background(Color.green.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(activity.sport.displayName)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)

                HStack(spacing: 8) {
                    if activity.distance > 0 {
                        Text(formatDistance(activity.distance))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(formatDuration(activity.duration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding()
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

    // MARK: - Body Battery

    @ViewBuilder
    private var bodyBatterySection: some View {
        if !todayBodyBatterySamples.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "battery.75percent")
                        .foregroundStyle(.blue)
                        .font(.subheadline)

                    Text("Body Battery")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text("\(currentBodyBattery)")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(.primary)
                }

                Chart(todayBodyBatterySamples, id: \.timestamp) { sample in
                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Level", sample.level)
                    )
                    .foregroundStyle(.blue)
                    .interpolationMethod(.catmullRom)

                    AreaMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Level", sample.level)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.25), Color.blue.opacity(0.0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)
                }
                .chartYScale(domain: 0...100)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                        AxisValueLabel(format: .dateTime.hour())
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { _ in
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

    // MARK: - Stress

    @ViewBuilder
    private var stressSection: some View {
        if !todayStressSamples.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "brain.head.profile")
                        .foregroundStyle(.orange)
                        .font(.subheadline)

                    Text("Stress")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text("\(currentStress)")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(.primary)
                }

                Chart(todayStressSamples, id: \.timestamp) { sample in
                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Stress", sample.stressScore)
                    )
                    .foregroundStyle(.orange)
                    .interpolationMethod(.catmullRom)

                    AreaMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Stress", sample.stressScore)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.orange.opacity(0.25), Color.orange.opacity(0.0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)
                }
                .chartYScale(domain: 0...100)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                        AxisValueLabel(format: .dateTime.hour())
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { _ in
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

    // MARK: - Empty State

    @ViewBuilder
    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("No Device Connected", systemImage: "applewatch.slash")
        } description: {
            Text("Pair a compatible fitness watch to start tracking your health and activity data.")
        } actions: {
            Button {
                AppLogger.ui.info("Pair a Device tapped from empty state")
                showingSettings = true
            } label: {
                Text("Pair a Device")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Formatting

    private func formatDistance(_ meters: Double) -> String {
        let km = meters / 1000.0
        if km >= 1 {
            return String(format: "%.2f km", km)
        }
        return String(format: "%.0f m", meters)
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        let seconds = Int(interval) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

#Preview {
    TodayView()
        .environment(SyncCoordinator(deviceManager: MockGarminDevice()))
        .modelContainer(for: [
            ConnectedDevice.self,
            Activity.self,
            TrackPoint.self,
            SleepSession.self,
            SleepStage.self,
            HeartRateSample.self,
            BodyBatterySample.self,
            StressSample.self,
            StepCount.self,
        ], inMemory: true)
}
