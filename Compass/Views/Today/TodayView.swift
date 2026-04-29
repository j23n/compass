import SwiftUI
import SwiftData
import CompassData
import CompassBLE

/// The main Today tab — connection status, dense vitals grid, and recent activities.
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

    @Query(sort: \StepSample.timestamp)
    private var allStepSamples: [StepSample]

    @State private var showingSettings = false

    // MARK: - Time windows

    private var startOfToday: Date { Calendar.current.startOfDay(for: Date()) }
    private var last24h: Date { Date().addingTimeInterval(-86400) }

    private var hasDevice: Bool { !connectedDevices.isEmpty }

    // MARK: - Activities (last 24 h)

    private var recentActivities: [Activity] {
        allActivities.filter { $0.startDate >= last24h }
    }

    // MARK: - Sleep

    private var lastSleep: SleepSession? { allSleepSessions.first }

    private var weekAgo: Date { Calendar.current.date(byAdding: .day, value: -7, to: Date())! }

    // MARK: - Heart rate

    private var todayRestingHR: [HeartRateSample] {
        allHeartRateSamples.filter { $0.timestamp >= startOfToday && $0.context == .resting }
    }

    private var heartRateMetric: VitalsMetric {
        let history = allHeartRateSamples
            .filter { $0.timestamp >= weekAgo && $0.context == .resting }
            .map { TrendDataPoint(date: $0.timestamp, value: Double($0.bpm)) }
        let current = todayRestingHR.min(by: { $0.bpm < $1.bpm })?.bpm
        let sparkline = todayRestingHR.suffix(20).map { Double($0.bpm) }
        return VitalsMetric(current: current, sparkline: sparkline, history: history)
    }

    // MARK: - Body battery

    private var todayBodyBattery: [BodyBatterySample] {
        allBodyBattery.filter { $0.timestamp >= startOfToday }
    }

    private var bodyBatteryMetric: VitalsMetric {
        let history = allBodyBattery
            .filter { $0.timestamp >= weekAgo }
            .map { TrendDataPoint(date: $0.timestamp, value: Double($0.level)) }
        let current = todayBodyBattery.last?.level
        let sparkline = todayBodyBattery.suffix(30).map { Double($0.level) }
        return VitalsMetric(current: current, sparkline: sparkline, history: history)
    }

    // MARK: - Stress

    private var todayStress: [StressSample] {
        allStress.filter { $0.timestamp >= startOfToday }
    }

    private var stressMetric: VitalsMetric {
        let history = allStress
            .filter { $0.timestamp >= weekAgo }
            .map { TrendDataPoint(date: $0.timestamp, value: Double($0.stressScore)) }
        let current = todayStress.last?.stressScore
        let sparkline = todayStress.suffix(30).map { Double($0.stressScore) }
        return VitalsMetric(current: current, sparkline: sparkline, history: history)
    }

    // MARK: - Steps

    private var todayStepCounts: [StepCount] {
        allSteps.filter { $0.date >= startOfToday }
    }

    private var stepsMetric: VitalsMetric {
        // 7-day daily totals for history chart
        let cal = Calendar.current
        let grouped = Dictionary(grouping: allSteps.filter { $0.date >= weekAgo }) {
            cal.startOfDay(for: $0.date)
        }
        let history = grouped
            .map { day, counts in TrendDataPoint(date: day, value: Double(counts.reduce(0) { $0 + $1.steps })) }
            .sorted { $0.date < $1.date }

        // Hourly sparkline for today using per-minute StepSample records
        let todaySamples = allStepSamples.filter { $0.timestamp >= startOfToday }
        var buckets = [Double](repeating: 0, count: 24)
        for sample in todaySamples {
            let hour = cal.component(.hour, from: sample.timestamp)
            buckets[hour] += Double(sample.steps)
        }
        var lastHour = 23
        while lastHour > 0 && buckets[lastHour] == 0 { lastHour -= 1 }
        let sparkline = todaySamples.isEmpty ? [] : Array(buckets[0...lastHour])

        let total = todayStepCounts.reduce(0) { $0 + $1.steps }
        return VitalsMetric(current: todayStepCounts.isEmpty ? nil : total, sparkline: sparkline, history: history)
    }

    // MARK: - Active minutes

    private var activeMinutesMetric: VitalsMetric {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: allSteps.filter { $0.date >= weekAgo }) {
            cal.startOfDay(for: $0.date)
        }
        let history = grouped
            .map { day, counts in TrendDataPoint(date: day, value: Double(counts.reduce(0) { $0 + $1.intensityMinutes })) }
            .sorted { $0.date < $1.date }
        let todayCounts = allSteps.filter { $0.date >= startOfToday }
        let sparkline = todayCounts.map { Double($0.intensityMinutes) }
        let total = todayCounts.reduce(0) { $0 + $1.intensityMinutes }
        return VitalsMetric(current: todayCounts.isEmpty ? nil : total, sparkline: sparkline, history: history)
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
                if let device = connectedDevices.first,
                   case .disconnected = syncCoordinator.connectionState {
                    Task { await syncCoordinator.reconnect(device: device) }
                }
            }
        }
    }

    // MARK: - Dashboard

    @ViewBuilder
    private var dashboardContent: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                connectionPill
                vitalsSection
                activitiesSection
            }
            .padding()
        }
        .refreshable {
            await syncCoordinator.sync(context: modelContext)
        }
    }

    // MARK: - Connection pill

    @ViewBuilder
    private var connectionPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(connectionDotColor)
                .frame(width: 8, height: 8)
            Text(connectionLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var connectionDotColor: Color {
        switch syncCoordinator.connectionState {
        case .connected: .green
        case .connecting: .orange
        case .disconnected, .failed: .gray
        }
    }

    private var connectionLabel: String {
        switch syncCoordinator.connectionState {
        case .connected(let name): "Connected to \(name)"
        case .connecting: "Connecting..."
        case .disconnected: "Watch not connected"
        case .failed: "Connection failed"
        }
    }

    // MARK: - Vitals

    @ViewBuilder
    private var vitalsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Vitals")
                .font(.headline)

            VitalsGridView(
                sleepScore: lastSleep?.score,
                sleepStages: lastSleep?.stages ?? [],
                heartRate: heartRateMetric,
                bodyBattery: bodyBatteryMetric,
                stress: stressMetric,
                steps: stepsMetric,
                activeMinutes: activeMinutesMetric
            )
        }
    }

    // MARK: - Activities

    @ViewBuilder
    private var activitiesSection: some View {
        if !recentActivities.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recent Activities")
                    .font(.headline)

                ForEach(recentActivities) { activity in
                    NavigationLink(destination: ActivityDetailView(activity: activity)) {
                        ActivityRowView(activity: activity)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
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
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("No Device Connected", systemImage: "applewatch.slash")
        } description: {
            Text("Pair a compatible fitness watch to start tracking your health and activity data.")
        } actions: {
            Button {
                showingSettings = true
            } label: {
                Text("Pair a Device")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
        }
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
            StepSample.self,
        ], inMemory: true)
}
