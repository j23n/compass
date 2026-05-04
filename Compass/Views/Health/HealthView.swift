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

    @Query(sort: \StressSample.timestamp)
    private var allStress: [StressSample]

    @Query(sort: \StepSample.timestamp)
    private var allStepSamples: [StepSample]

    @Query(sort: \IntensitySample.timestamp)
    private var allIntensity: [IntensitySample]

    @Query(sort: \SpO2Sample.timestamp)
    private var allSpO2: [SpO2Sample]

    // MARK: - Data points (all-time; filtering happens inside InteractiveTrendCard / HealthDetailView)

    /// All HR readings (any context) — bucketing in HealthDetailView produces
    /// hourly min/max/avg ranges for Day view and daily ranges for Week/Month/Year.
    private var heartRateData: [TrendDataPoint] {
        allHeartRate.map { TrendDataPoint(date: $0.timestamp, value: Double($0.bpm)) }
    }

    /// Resting-only HR samples — sparse (≈one per minute when worn at rest), useful
    /// as a separate trend from continuous HR.
    private var restingHRData: [TrendDataPoint] {
        allHeartRate
            .filter { $0.context == .resting }
            .map { TrendDataPoint(date: $0.timestamp, value: Double($0.bpm)) }
    }

    private var hrvData: [TrendDataPoint] {
        allHRV.map { TrendDataPoint(date: $0.timestamp, value: $0.rmssd) }
    }

    private var stressData: [TrendDataPoint] {
        allStress.map { TrendDataPoint(date: $0.timestamp, value: Double($0.stressScore)) }
    }

    /// Hourly step bins from StepSample — works for Day view (per-hour) and
    /// Week/Month/Year (makeTrendBuckets aggregates to daily totals automatically).
    private var stepsData: [TrendDataPoint] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: allStepSamples) { sample in
            cal.dateInterval(of: .hour, for: sample.timestamp)?.start
                ?? cal.startOfDay(for: sample.timestamp)
        }
        return grouped
            .map { hourStart, samples in
                TrendDataPoint(date: hourStart, value: Double(samples.reduce(0) { $0 + $1.steps }))
            }
            .sorted { $0.date < $1.date }
    }

    /// Per-minute intensity samples bucketed hourly so Day view shows minutes/hour
    /// and Week/Month/Year show minutes/day after makeTrendBuckets aggregates.
    private var activeMinutesData: [TrendDataPoint] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: allIntensity) { sample in
            cal.dateInterval(of: .hour, for: sample.timestamp)?.start
                ?? cal.startOfDay(for: sample.timestamp)
        }
        return grouped
            .map { hourStart, samples in
                TrendDataPoint(date: hourStart, value: Double(samples.reduce(0) { $0 + $1.minutes }))
            }
            .sorted { $0.date < $1.date }
    }

    private var spo2Data: [TrendDataPoint] {
        allSpO2.map { TrendDataPoint(date: $0.timestamp, value: Double($0.percent)) }
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
                        title: "Heart Rate",
                        icon: "heart.fill",
                        color: .red,
                        unit: "bpm",
                        data: heartRateData,
                        selectedRange: selectedRange,
                        valueFormatter: { "\(Int($0)) bpm" }
                    )
                    InteractiveTrendCard(
                        title: "Resting Heart Rate",
                        icon: "heart.text.square.fill",
                        color: .pink,
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
                    SleepStagesCard(sessions: allSleep, selectedRange: selectedRange)

                    // Recovery
                    sectionHeader(icon: "bolt.fill", title: "Recovery", color: .blue)
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

                    // Vitals
                    sectionHeader(icon: "lungs.fill", title: "Vitals", color: .mint)
                    InteractiveTrendCard(
                        title: "SpO₂",
                        icon: "lungs.fill",
                        color: .mint,
                        unit: "%",
                        data: spo2Data,
                        selectedRange: selectedRange,
                        valueFormatter: { "\(Int($0)) %" }
                    )
                }
                .padding()
            }
            .navigationTitle("Health")
            .connectionStatusToolbar()
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
            StressSample.self,
            StepSample.self,
            IntensitySample.self,
            SpO2Sample.self,
        ], inMemory: true)
}
