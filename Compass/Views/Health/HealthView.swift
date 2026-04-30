import SwiftUI
import SwiftData
import Charts
import CompassData

/// The Health tab — metrics grouped into sections, each with a drag-to-read chart card.
struct HealthView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var selectedRange: TrendTimeRange = .week

    @Query(sort: \HeartRateSample.timestamp)
    private var allHeartRate: [HeartRateSample]

    @Query(sort: \HRVSample.timestamp)
    private var allHRV: [HRVSample]

    @Query(sort: \SleepSession.endDate, order: .reverse)
    private var allSleep: [SleepSession]

    @Query(sort: \BodyBatterySample.timestamp)
    private var allBodyBattery: [BodyBatterySample]

    @Query(sort: \StressSample.timestamp)
    private var allStress: [StressSample]

    @Query(sort: \StepCount.date)
    private var allSteps: [StepCount]

    // MARK: - Date range

    private var dateRange: ClosedRange<Date> {
        let now = Date()
        let cal = Calendar.current
        let start: Date
        switch selectedRange {
        case .day:   start = cal.date(byAdding: .day,   value:  -1, to: now)!
        case .week:  start = cal.date(byAdding: .day,   value:  -7, to: now)!
        case .month: start = cal.date(byAdding: .month, value:  -1, to: now)!
        case .year:  start = cal.date(byAdding: .year,  value:  -1, to: now)!
        }
        return start...now
    }

    private func monthlySum(_ points: [TrendDataPoint]) -> [TrendDataPoint] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: points) {
            cal.dateInterval(of: .month, for: $0.date)?.start ?? $0.date
        }
        return groups.map { TrendDataPoint(date: $0.key, value: $0.value.reduce(0) { $0 + $1.value }) }
            .sorted { $0.date < $1.date }
    }

    private func monthlyAverage(_ points: [TrendDataPoint]) -> [TrendDataPoint] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: points) {
            cal.dateInterval(of: .month, for: $0.date)?.start ?? $0.date
        }
        return groups.compactMap { key, pts in
            guard !pts.isEmpty else { return nil }
            return TrendDataPoint(date: key, value: pts.reduce(0) { $0 + $1.value } / Double(pts.count))
        }.sorted { $0.date < $1.date }
    }

    // MARK: - Data points

    private var restingHRData: [TrendDataPoint] {
        let range = dateRange
        return allHeartRate
            .filter { $0.context == .resting && range.contains($0.timestamp) }
            .map { TrendDataPoint(date: $0.timestamp, value: Double($0.bpm)) }
    }

    private var hrvData: [TrendDataPoint] {
        let range = dateRange
        return allHRV
            .filter { range.contains($0.timestamp) }
            .map { TrendDataPoint(date: $0.timestamp, value: $0.rmssd) }
    }

    private var sleepDurationData: [TrendDataPoint] {
        let range = dateRange
        let daily = allSleep
            .filter { range.contains($0.startDate) }
            .map { TrendDataPoint(date: $0.startDate, value: $0.endDate.timeIntervalSince($0.startDate) / 3600.0) }
            .sorted { $0.date < $1.date }
        return selectedRange == .year ? monthlyAverage(daily) : daily
    }

    private var bodyBatteryData: [TrendDataPoint] {
        let range = dateRange
        return allBodyBattery
            .filter { range.contains($0.timestamp) }
            .map { TrendDataPoint(date: $0.timestamp, value: Double($0.level)) }
    }

    private var stressData: [TrendDataPoint] {
        let range = dateRange
        return allStress
            .filter { range.contains($0.timestamp) }
            .map { TrendDataPoint(date: $0.timestamp, value: Double($0.stressScore)) }
    }

    private var stepsData: [TrendDataPoint] {
        let range = dateRange
        let daily = allSteps
            .filter { range.contains($0.date) }
            .map { TrendDataPoint(date: $0.date, value: Double($0.steps)) }
        return selectedRange == .year ? monthlySum(daily) : daily
    }

    private var activeMinutesData: [TrendDataPoint] {
        let range = dateRange
        let daily = allSteps
            .filter { range.contains($0.date) }
            .map { TrendDataPoint(date: $0.date, value: Double($0.intensityMinutes)) }
        return selectedRange == .year ? monthlySum(daily) : daily
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    rangePicker

                    // Heart
                    sectionHeader(icon: "heart.fill", title: "Heart", color: .red)
                    InteractiveTrendCard(
                        title: "Resting Heart Rate",
                        icon: "heart.fill",
                        color: .red,
                        unit: "bpm",
                        data: restingHRData,
                        selectedRange: selectedRange,
                        valueFormatter: { "\(Int($0)) bpm" }
                    )
                    InteractiveTrendCard(
                        title: "Heart Rate Variability",
                        icon: "waveform.path.ecg",
                        color: .purple,
                        unit: "ms",
                        data: hrvData,
                        selectedRange: selectedRange,
                        valueFormatter: { "\(Int($0)) ms" }
                    )

                    // Sleep
                    sectionHeader(icon: "bed.double.fill", title: "Sleep", color: .indigo)
                    InteractiveTrendCard(
                        title: "Sleep Duration",
                        icon: "bed.double.fill",
                        color: .indigo,
                        unit: "hr",
                        data: sleepDurationData,
                        useBarChart: true,
                        selectedRange: selectedRange,
                        valueFormatter: { String(format: "%.1f hr", $0) }
                    )

                    // Recovery
                    sectionHeader(icon: "bolt.fill", title: "Recovery", color: .blue)
                    InteractiveTrendCard(
                        title: "Body Battery",
                        icon: "bolt.fill",
                        color: .blue,
                        unit: "",
                        data: bodyBatteryData,
                        selectedRange: selectedRange,
                        valueFormatter: { "\(Int($0))" }
                    )
                    InteractiveTrendCard(
                        title: "Stress",
                        icon: "brain.head.profile",
                        color: .orange,
                        unit: "",
                        data: stressData,
                        selectedRange: selectedRange,
                        valueFormatter: { "\(Int($0))" }
                    )

                    // Activity
                    sectionHeader(icon: "figure.run", title: "Activity", color: .green)
                    InteractiveTrendCard(
                        title: "Steps",
                        icon: "figure.walk",
                        color: .green,
                        unit: "steps",
                        data: stepsData,
                        useBarChart: true,
                        selectedRange: selectedRange,
                        valueFormatter: { "\(Int($0))" }
                    )
                    InteractiveTrendCard(
                        title: "Active Minutes",
                        icon: "figure.run",
                        color: .teal,
                        unit: "min",
                        data: activeMinutesData,
                        useBarChart: true,
                        selectedRange: selectedRange,
                        valueFormatter: { "\(Int($0)) min" }
                    )
                }
                .padding()
            }
            .navigationTitle("Health")
        }
    }

    // MARK: - Helpers

    private var rangePicker: some View {
        Picker("Time Range", selection: $selectedRange) {
            ForEach(TrendTimeRange.allCases) { range in
                Text(range.rawValue).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func sectionHeader(icon: String, title: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(color)
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)
            Spacer()
        }
        .padding(.top, 4)
    }
}

#Preview {
    HealthView()
        .modelContainer(for: [
            HeartRateSample.self,
            HRVSample.self,
            SleepSession.self,
            SleepStage.self,
            BodyBatterySample.self,
            StressSample.self,
            StepCount.self,
        ], inMemory: true)
}
