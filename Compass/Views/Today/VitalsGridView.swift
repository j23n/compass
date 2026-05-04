import SwiftUI
import Charts
import CompassData

/// Data bundle for a single vitals metric card.
struct VitalsMetric {
    let current: Int?                               // nil → display "--"
    let lastReadingAt: Date?                        // nil → no timestamp line
    let windowSamples: [(date: Date, value: Double)] // last 4h for the mini chart
    let history: [TrendDataPoint]                   // full history for the detail view
}

/// Compact 2-column grid of today's key vitals.
struct VitalsGridView: View {
    let heartRate: VitalsMetric
    let stress: VitalsMetric
    let steps: VitalsMetric
    let activeMinutes: VitalsMetric
    let spo2: VitalsMetric

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            heartRateCard
            stressCard
            stepsCard
            activeMinutesCard
            spo2Card
        }
    }

    // MARK: - Heart Rate

    private var heartRateCard: some View {
        NavigationLink {
            HealthDetailView(
                metricTitle: "Heart Rate",
                metricUnit: "bpm",
                color: .red,
                icon: "heart.fill",
                data: heartRate.history,
                valueFormatter: { "\(Int($0)) bpm" }
            )
        } label: {
            cardShell(icon: "heart.fill", label: "Heart Rate", color: .red) {
                metricValue(heartRate.current.map { "\($0)" }, unit: "bpm")
                readingLine(for: heartRate)
                chartSlot(!heartRate.windowSamples.isEmpty) {
                    miniChart(for: heartRate, style: .line(color: .red))
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
                readingLine(for: stress)
                chartSlot(!stress.windowSamples.isEmpty) {
                    miniChart(for: stress, style: .line(color: .orange))
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
                readingLine(for: steps)
                chartSlot(!steps.windowSamples.isEmpty) {
                    miniChart(for: steps, style: .bars(color: .green))
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
                readingLine(for: activeMinutes)
                chartSlot(!activeMinutes.windowSamples.isEmpty) {
                    miniChart(for: activeMinutes, style: .bars(color: .teal))
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - SpO2

    private var spo2Card: some View {
        NavigationLink {
            HealthDetailView(
                metricTitle: "Blood Oxygen",
                metricUnit: "%",
                color: .cyan,
                icon: "lungs.fill",
                data: spo2.history,
                valueFormatter: { "\(Int($0))%" }
            )
        } label: {
            cardShell(icon: "lungs.fill", label: "Blood Oxygen", color: .cyan) {
                metricValue(spo2.current.map { "\($0)" }, unit: "%")
                readingLine(for: spo2)
                chartSlot(!spo2.windowSamples.isEmpty) {
                    miniChart(for: spo2, style: .line(color: .cyan))
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

    /// "N minutes ago" / "at HH:MM" line, re-rendered every minute via TimelineView.
    @ViewBuilder
    private func readingLine(for metric: VitalsMetric) -> some View {
        if let ts = metric.lastReadingAt {
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                Text(ts.relativeReadingDescription())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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

    private func miniChart(for metric: VitalsMetric, style: MiniWindowChart.Style) -> some View {
        MiniWindowChart(samples: metric.windowSamples, window: 4 * 3600, style: style)
    }
}
