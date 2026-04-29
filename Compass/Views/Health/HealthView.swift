import SwiftUI
import SwiftData
import Charts
import CompassData

/// The Health/Trends tab showing trend charts for all health metrics.
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

    private var dateRange: ClosedRange<Date> {
        let now = Date()
        let calendar = Calendar.current
        let start: Date
        switch selectedRange {
        case .week:
            start = calendar.date(byAdding: .day, value: -7, to: now)!
        case .month:
            start = calendar.date(byAdding: .month, value: -1, to: now)!
        case .threeMonths:
            start = calendar.date(byAdding: .month, value: -3, to: now)!
        case .year:
            start = calendar.date(byAdding: .year, value: -1, to: now)!
        }
        return start...now
    }

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
        return allSleep
            .filter { range.contains($0.startDate) }
            .map {
                let hours = $0.endDate.timeIntervalSince($0.startDate) / 3600.0
                return TrendDataPoint(date: $0.startDate, value: hours)
            }
            .sorted { $0.date < $1.date }
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
        return allSteps
            .filter { range.contains($0.date) }
            .map { TrendDataPoint(date: $0.date, value: Double($0.steps)) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                let _ = AppLogger.ui.debug("HealthView rendering — range: \(selectedRange.rawValue), HR: \(restingHRData.count), HRV: \(hrvData.count), sleep: \(sleepDurationData.count), steps: \(stepsData.count)")
                LazyVStack(spacing: 28) {
                    // Segmented time range picker
                    Picker("Time Range", selection: $selectedRange) {
                        ForEach(TrendTimeRange.allCases) { range in
                            Text(range.rawValue).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 4)

                    // Resting HR
                    NavigationLink {
                        HealthDetailView(
                            metricTitle: "Resting Heart Rate",
                            metricUnit: "bpm",
                            color: .red,
                            icon: "heart.fill",
                            data: restingHRData,
                            valueFormatter: { "\(Int($0)) bpm" }
                        )
                    } label: {
                        trendSection(
                            title: "Resting Heart Rate",
                            color: .red,
                            data: restingHRData,
                            valueFormatter: { "\(Int($0)) bpm" }
                        )
                    }
                    .buttonStyle(.plain)

                    // HRV
                    NavigationLink {
                        HealthDetailView(
                            metricTitle: "Heart Rate Variability",
                            metricUnit: "ms",
                            color: .purple,
                            icon: "waveform.path.ecg",
                            data: hrvData,
                            valueFormatter: { "\(Int($0)) ms" }
                        )
                    } label: {
                        trendSection(
                            title: "Heart Rate Variability",
                            color: .purple,
                            data: hrvData,
                            valueFormatter: { "\(Int($0)) ms" }
                        )
                    }
                    .buttonStyle(.plain)

                    // Sleep duration
                    NavigationLink {
                        HealthDetailView(
                            metricTitle: "Sleep Duration",
                            metricUnit: "hr",
                            color: .purple,
                            icon: "bed.double.fill",
                            data: sleepDurationData,
                            valueFormatter: { String(format: "%.1f hr", $0) }
                        )
                    } label: {
                        trendSection(
                            title: "Sleep Duration",
                            color: .purple,
                            data: sleepDurationData,
                            valueFormatter: { String(format: "%.1f hr", $0) }
                        )
                    }
                    .buttonStyle(.plain)

                    // Body Battery
                    NavigationLink {
                        HealthDetailView(
                            metricTitle: "Body Battery",
                            metricUnit: "",
                            color: .blue,
                            icon: "battery.75percent",
                            data: bodyBatteryData,
                            valueFormatter: { "\(Int($0))" }
                        )
                    } label: {
                        trendSection(
                            title: "Body Battery",
                            color: .blue,
                            data: bodyBatteryData,
                            valueFormatter: { "\(Int($0))" }
                        )
                    }
                    .buttonStyle(.plain)

                    // Stress
                    NavigationLink {
                        HealthDetailView(
                            metricTitle: "Stress",
                            metricUnit: "",
                            color: .orange,
                            icon: "brain.head.profile",
                            data: stressData,
                            valueFormatter: { "\(Int($0))" }
                        )
                    } label: {
                        trendSection(
                            title: "Stress Average",
                            color: .orange,
                            data: stressData,
                            valueFormatter: { "\(Int($0))" }
                        )
                    }
                    .buttonStyle(.plain)

                    // Steps
                    NavigationLink {
                        HealthDetailView(
                            metricTitle: "Steps",
                            metricUnit: "steps",
                            color: .green,
                            icon: "figure.walk",
                            data: stepsData,
                            valueFormatter: { "\(Int($0))" }
                        )
                    } label: {
                        trendSection(
                            title: "Steps",
                            color: .green,
                            data: stepsData,
                            valueFormatter: { "\(Int($0))" }
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding()
            }
            .navigationTitle("Health")
        }
    }

    @ViewBuilder
    private func trendSection(
        title: String,
        color: Color,
        data: [TrendDataPoint],
        valueFormatter: @escaping @Sendable (Double) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            if data.isEmpty {
                Text("No data available")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(height: 100)
                    .frame(maxWidth: .infinity)
            } else {
                Chart(data) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Value", point.value)
                    )
                    .foregroundStyle(color)
                    .interpolationMethod(.catmullRom)

                    AreaMark(
                        x: .value("Date", point.date),
                        y: .value("Value", point.value)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [color.opacity(0.2), color.opacity(0.0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine()
                        AxisValueLabel()
                    }
                }
                .frame(height: 150)
            }

            HStack {
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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
