import SwiftUI
import Charts
import CompassData

/// Data bundle for a single vitals metric card.
struct VitalsMetric {
    let current: Int?           // nil → display "--"
    let sparkline: [Double]     // compact window for the mini chart
    let history: [TrendDataPoint] // full history for the detail view
}

/// Compact 2-column grid of today's key vitals.
struct VitalsGridView: View {
    let sleepScore: Int?
    let sleepStages: [SleepStage]

    let heartRate: VitalsMetric
    let bodyBattery: VitalsMetric
    let stress: VitalsMetric
    let steps: VitalsMetric
    let activeMinutes: VitalsMetric

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            sleepCard
            heartRateCard
            bodyBatteryCard
            stressCard
            stepsCard
            activeMinutesCard
        }
    }

    // MARK: - Sleep (no detail view)

    private var sleepCard: some View {
        cardShell(icon: "bed.double.fill", label: "Sleep", color: .purple) {
            metricValue(sleepScore.map { "\($0)" }, unit: nil)
            chartSlot(!sleepStages.isEmpty) { miniSleepBar }
        }
    }

    // MARK: - Heart Rate

    private var heartRateCard: some View {
        NavigationLink {
            HealthDetailView(
                metricTitle: "Resting Heart Rate",
                metricUnit: "bpm",
                color: .red,
                icon: "heart.fill",
                data: heartRate.history,
                valueFormatter: { "\(Int($0)) bpm" }
            )
        } label: {
            cardShell(icon: "heart.fill", label: "Resting HR", color: .red) {
                metricValue(heartRate.current.map { "\($0)" }, unit: "bpm")
                chartSlot(!heartRate.sparkline.isEmpty) {
                    SparklineChart(data: heartRate.sparkline, color: .red)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Body Battery

    private var bodyBatteryCard: some View {
        NavigationLink {
            HealthDetailView(
                metricTitle: "Body Battery",
                metricUnit: "%",
                color: .blue,
                icon: "bolt.fill",
                data: bodyBattery.history,
                valueFormatter: { "\(Int($0))%" }
            )
        } label: {
            cardShell(icon: "bolt.fill", label: "Body Battery", color: .blue) {
                metricValue(bodyBattery.current.map { "\($0)" }, unit: "%")
                chartSlot(!bodyBattery.sparkline.isEmpty) {
                    SparklineChart(data: bodyBattery.sparkline, color: .blue)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Stress

    private var stressCard: some View {
        NavigationLink {
            HealthDetailView(
                metricTitle: "Stress",
                metricUnit: "",
                color: .orange,
                icon: "brain.head.profile",
                data: stress.history,
                valueFormatter: { "\(Int($0))" }
            )
        } label: {
            cardShell(icon: "brain.head.profile", label: "Stress", color: .orange) {
                metricValue(stress.current.map { "\($0)" }, unit: nil)
                chartSlot(!stress.sparkline.isEmpty) {
                    SparklineChart(data: stress.sparkline, color: .orange)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Steps

    private var stepsCard: some View {
        NavigationLink {
            HealthDetailView(
                metricTitle: "Steps",
                metricUnit: "steps",
                color: .green,
                icon: "figure.walk",
                data: steps.history,
                useBarChart: true,
                valueFormatter: { steps in
                    let n = Int(steps)
                    return n >= 1000
                        ? String(format: "%.1fk", Double(n) / 1000)
                        : "\(n)"
                }
            )
        } label: {
            cardShell(icon: "figure.walk", label: "Steps", color: .green) {
                metricValue(steps.current.map { $0 >= 1000
                    ? String(format: "%.1fk", Double($0) / 1000)
                    : "\($0)"
                }, unit: nil)
                chartSlot(!steps.sparkline.isEmpty) {
                    SparklineChart(data: steps.sparkline, color: .green)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Active Minutes

    private var activeMinutesCard: some View {
        NavigationLink {
            HealthDetailView(
                metricTitle: "Active Minutes",
                metricUnit: "min",
                color: .teal,
                icon: "figure.run",
                data: activeMinutes.history,
                useBarChart: true,
                valueFormatter: { "\(Int($0)) min" }
            )
        } label: {
            cardShell(icon: "figure.run", label: "Active Min", color: .teal) {
                metricValue(activeMinutes.current.map { "\($0)" }, unit: "min")
                chartSlot(!activeMinutes.sparkline.isEmpty) {
                    SparklineChart(data: activeMinutes.sparkline, color: .teal)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Shared card shell

    @ViewBuilder
    private func cardShell<Content: View>(
        icon: String, label: String, color: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption).foregroundStyle(color)
                Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 4) {
                content()
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 94, alignment: .topLeading)
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(0.07), radius: 5, x: 0, y: 2)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
    }

    // MARK: - Helpers

    /// Bold value + optional unit label, or "--" when value is nil.
    @ViewBuilder
    private func metricValue(_ text: String?, unit: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            if let t = text {
                Text(t).font(.title2).fontWeight(.bold)
                if let u = unit {
                    Text(u).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("--").font(.title2).fontWeight(.bold).foregroundStyle(.secondary)
            }
        }
    }

    /// Fixed-height slot that shows the chart when data is present, or a clear
    /// placeholder when it isn't — keeps all cards the same height.
    @ViewBuilder
    private func chartSlot<Chart: View>(_ hasData: Bool, @ViewBuilder chart: () -> Chart) -> some View {
        Group {
            if hasData { chart() } else { Color.clear }
        }
        .frame(height: 24)
    }

    // MARK: - Sleep stage mini-bar

    private var miniSleepBar: some View {
        let groups = stageDurations()
        let total = groups.reduce(0.0) { $0 + $1.1 }
        return GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, pair in
                    let fraction = total > 0 ? pair.1 / total : 0
                    Rectangle()
                        .fill(stageColor(pair.0))
                        .frame(width: geo.size.width * fraction)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 6)
    }

    private func stageDurations() -> [(SleepStageType, TimeInterval)] {
        let order: [SleepStageType] = [.deep, .rem, .light, .awake]
        let grouped = Dictionary(grouping: sleepStages, by: \.stage)
        return order.compactMap { type in
            guard let arr = grouped[type], !arr.isEmpty else { return nil }
            let dur = arr.reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
            return (type, dur)
        }
    }

    private func stageColor(_ stage: SleepStageType) -> Color {
        switch stage {
        case .deep: .indigo
        case .rem: .purple
        case .light: Color(.systemGray4)
        case .awake: Color(.systemGray6)
        }
    }
}
