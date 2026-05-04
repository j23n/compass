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

    @Query(sort: \StressSample.timestamp)
    private var allStress: [StressSample]

    @Query(sort: \StepCount.date)
    private var allSteps: [StepCount]

    @Query(sort: \StepSample.timestamp)
    private var allStepSamples: [StepSample]

    @Query(sort: \SpO2Sample.timestamp, order: .reverse)
    private var allSpO2: [SpO2Sample]

    @Query(sort: \IntensitySample.timestamp)
    private var activeIntensitySamples: [IntensitySample]

    @State private var showingSettings = false

    // MARK: - Time windows

    private var startOfToday: Date { Calendar.current.startOfDay(for: Date()) }
    private var last24h: Date { Date().addingTimeInterval(-86400) }
    private var windowStart: Date { Date().addingTimeInterval(-4 * 3600) }

    private var hasDevice: Bool { !connectedDevices.isEmpty }

    // MARK: - Activities (last 24 h)

    private var recentActivities: [Activity] {
        allActivities.filter { $0.startDate >= last24h }
    }

    // MARK: - Sleep

    /// The most recent sleep session that ended on the current calendar day.
    /// Yesterday's sleep is intentionally hidden — the user wants the Today
    /// view's sleep card to reflect "today" only and show a placeholder
    /// otherwise.
    private var todaySleep: SleepSession? {
        allSleepSessions.first(where: { $0.endDate >= startOfToday })
    }

    private var weekAgo: Date { Calendar.current.date(byAdding: .day, value: -7, to: Date())! }

    // MARK: - Heart rate

    /// Latest HR sample regardless of context — keeps the card useful even when no
    /// resting reading has landed today yet.
    private var heartRateMetric: VitalsMetric {
        let history = allHeartRateSamples
            .filter { $0.timestamp >= weekAgo }
            .map { TrendDataPoint(date: $0.timestamp, value: Double($0.bpm)) }
        let last = allHeartRateSamples.last
        let windowSamples = allHeartRateSamples
            .filter { $0.timestamp >= windowStart }
            .map { (date: $0.timestamp, value: Double($0.bpm)) }
        return VitalsMetric(current: last.map { $0.bpm },
                            lastReadingAt: last?.timestamp,
                            windowSamples: windowSamples, history: history)
    }

    /// Resting-only HR samples — same source as Health → Heart → Resting Heart Rate.
    private var restingHeartRateMetric: VitalsMetric {
        let resting = allHeartRateSamples.filter { $0.context == .resting }
        let history = resting
            .filter { $0.timestamp >= weekAgo }
            .map { TrendDataPoint(date: $0.timestamp, value: Double($0.bpm)) }
        let last = resting.last
        let windowSamples = resting
            .filter { $0.timestamp >= windowStart }
            .map { (date: $0.timestamp, value: Double($0.bpm)) }
        return VitalsMetric(current: last.map { $0.bpm },
                            lastReadingAt: last?.timestamp,
                            windowSamples: windowSamples, history: history)
    }

    // MARK: - Stress

    private var stressMetric: VitalsMetric {
        let history = allStress
            .filter { $0.timestamp >= weekAgo }
            .map { TrendDataPoint(date: $0.timestamp, value: Double($0.stressScore)) }
        let last = allStress.last
        let windowSamples = allStress
            .filter { $0.timestamp >= windowStart }
            .map { (date: $0.timestamp, value: Double($0.stressScore)) }
        return VitalsMetric(current: last.map { $0.stressScore },
                            lastReadingAt: last?.timestamp,
                            windowSamples: windowSamples, history: history)
    }

    // MARK: - Steps

    private var todayStepCounts: [StepCount] {
        allSteps.filter { $0.date >= startOfToday }
    }

    private var stepsMetric: VitalsMetric {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: allSteps.filter { $0.date >= weekAgo }) {
            cal.startOfDay(for: $0.date)
        }
        let history = grouped
            .map { day, counts in TrendDataPoint(date: day, value: Double(counts.reduce(0) { $0 + $1.steps })) }
            .sorted { $0.date < $1.date }

        let total = todayStepCounts.reduce(0) { $0 + $1.steps }
        let lastReadingAt = allStepSamples.last?.timestamp
        return VitalsMetric(
            current: total,
            lastReadingAt: lastReadingAt,
            windowSamples: [],
            history: history
        )
    }

    // MARK: - Active minutes

    private var activeMinutesMetric: VitalsMetric {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: activeIntensitySamples.filter { $0.timestamp >= weekAgo }) {
            cal.startOfDay(for: $0.timestamp)
        }
        let history = grouped
            .map { day, samples in TrendDataPoint(date: day, value: Double(samples.reduce(0) { $0 + $1.minutes })) }
            .sorted { $0.date < $1.date }
        let total = activeIntensitySamples
            .filter { $0.timestamp >= startOfToday }
            .reduce(0) { $0 + $1.minutes }

        let currentHourStart = cal.dateInterval(of: .hour, for: Date.now)!.start
        let windowSamples: [(date: Date, value: Double)] = (0..<4).reversed().map { i in
            let start = cal.date(byAdding: .hour, value: -i, to: currentHourStart)!
            let end = cal.date(byAdding: .hour, value: 1, to: start)!
            let sum = activeIntensitySamples
                .filter { $0.timestamp >= start && $0.timestamp < end }
                .reduce(0) { $0 + $1.minutes }
            return (start, Double(sum))
        }

        let lastReadingAt = activeIntensitySamples.last?.timestamp
        return VitalsMetric(
            current: total,
            lastReadingAt: lastReadingAt,
            windowSamples: windowSamples,
            history: history
        )
    }

    // MARK: - SpO2

    private var spo2Metric: VitalsMetric {
        let last = allSpO2.first   // reverse sort → first is latest
        let recent = allSpO2.filter { $0.timestamp >= windowStart }
        let history = allSpO2
            .filter { $0.timestamp >= weekAgo }
            .map { TrendDataPoint(date: $0.timestamp, value: Double($0.percent)) }
            .sorted { $0.date < $1.date }
        let windowSamples = recent
            .reversed()
            .map { (date: $0.timestamp, value: Double($0.percent)) }
        return VitalsMetric(
            current: last.map { Int($0.percent) },
            lastReadingAt: last?.timestamp,
            windowSamples: windowSamples,
            history: history
        )
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
            .connectionStatusToolbar()
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
                sleepSection
                vitalsSection
                activitiesSection
            }
            .padding()
        }
        .refreshable {
            await syncCoordinator.sync(context: modelContext)
        }
    }

    // MARK: - Sleep

    @ViewBuilder
    private var sleepSection: some View {
        if let session = todaySleep, !session.stages.isEmpty {
            SleepNightCard(session: session)
        } else {
            sleepPlaceholderCard
        }
    }

    private var sleepPlaceholderCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Sleep", systemImage: "bed.double.fill")
                    .font(.headline)
                    .foregroundStyle(.purple)
                Spacer()
            }
            Text("No sleep recorded")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: - Vitals

    @ViewBuilder
    private var vitalsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Vitals")
                .font(.headline)

            VitalsGridView(
                heartRate: heartRateMetric,
                restingHeartRate: restingHeartRateMetric,
                stress: stressMetric,
                steps: stepsMetric,
                activeMinutes: activeMinutesMetric,
                spo2: spo2Metric
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
    let container = try! ModelContainer(
        for: ConnectedDevice.self, Activity.self, TrackPoint.self, SleepSession.self,
             SleepStage.self, HeartRateSample.self, BodyBatterySample.self,
             StressSample.self, StepCount.self, StepSample.self,
             SpO2Sample.self, IntensitySample.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    TodayView()
        .environment(SyncCoordinator(deviceManager: MockGarminDevice(), modelContainer: container))
        .modelContainer(container)
}
