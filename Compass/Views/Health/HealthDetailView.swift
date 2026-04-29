import SwiftUI
import Charts

/// Fullscreen chart detail for a single health metric.
struct HealthDetailView: View {
    let metricTitle: String
    let metricUnit: String
    var color: Color = .blue
    var icon: String = "heart.fill"
    let data: [TrendDataPoint]
    var valueFormatter: @Sendable (Double) -> String = { String(format: "%.0f", $0) }

    @State private var selectedRange: TrendTimeRange = .week
    @State private var selectedDataPoint: TrendDataPoint?

    private var averageValue: Double {
        guard !data.isEmpty else { return 0 }
        return data.reduce(0) { $0 + $1.value } / Double(data.count)
    }

    private var minValue: Double {
        data.min(by: { $0.value < $1.value })?.value ?? 0
    }

    private var maxValue: Double {
        data.max(by: { $0.value < $1.value })?.value ?? 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header with current/latest value
                headerSection

                // Chart
                chartSection

                // Statistics summary
                statisticsSection
            }
            .padding()
        }
        .navigationTitle(metricTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)

            VStack(alignment: .leading, spacing: 2) {
                if let latest = data.last {
                    Text(valueFormatter(latest.value))
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundStyle(.primary)
                } else {
                    Text("--")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                }

                if !metricUnit.isEmpty {
                    Text(metricUnit)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
    }

    // MARK: - Chart

    @ViewBuilder
    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Time Range", selection: $selectedRange) {
                ForEach(TrendTimeRange.allCases) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .pickerStyle(.segmented)

            if data.isEmpty {
                ContentUnavailableView {
                    Label("No Data", systemImage: "chart.line.downtrend.xyaxis")
                } description: {
                    Text("No \(metricTitle.lowercased()) data available for this time range.")
                }
                .frame(height: 300)
            } else {
                Chart {
                    ForEach(data) { point in
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Value", point.value)
                        )
                        .foregroundStyle(color)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))

                        AreaMark(
                            x: .value("Date", point.date),
                            y: .value("Value", point.value)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [color.opacity(0.25), color.opacity(0.0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.catmullRom)
                    }

                    if let selected = selectedDataPoint {
                        RuleMark(x: .value("Selected", selected.date))
                            .foregroundStyle(.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .annotation(position: .top, spacing: 4) {
                                VStack(spacing: 2) {
                                    Text(valueFormatter(selected.value))
                                        .font(.caption)
                                        .fontWeight(.bold)
                                        .foregroundStyle(color)
                                    Text(selected.date, style: .date)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(.ultraThinMaterial)
                                }
                            }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { value in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel()
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { _ in
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { drag in
                                        let xPosition = drag.location.x
                                        guard let date: Date = proxy.value(atX: xPosition) else { return }
                                        selectedDataPoint = data.min(by: {
                                            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
                                        })
                                    }
                                    .onEnded { _ in
                                        selectedDataPoint = nil
                                    }
                            )
                    }
                }
                .frame(height: 300)
            }
        }
    }

    // MARK: - Statistics

    @ViewBuilder
    private var statisticsSection: some View {
        if !data.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text("Statistics")
                    .font(.headline)

                Grid(horizontalSpacing: 16, verticalSpacing: 12) {
                    GridRow {
                        statisticItem(label: "Average", value: valueFormatter(averageValue))
                        statisticItem(label: "Min", value: valueFormatter(minValue))
                        statisticItem(label: "Max", value: valueFormatter(maxValue))
                    }
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

    @ViewBuilder
    private func statisticItem(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    let sampleData: [TrendDataPoint] = {
        let calendar = Calendar.current
        let today = Date()
        return (0..<14).map { dayOffset in
            let date = calendar.date(byAdding: .day, value: -dayOffset, to: today)!
            let value = Double.random(in: 55...68)
            return TrendDataPoint(date: date, value: value)
        }.reversed()
    }()

    NavigationStack {
        HealthDetailView(
            metricTitle: "Resting Heart Rate",
            metricUnit: "bpm",
            color: .red,
            icon: "heart.fill",
            data: sampleData,
            valueFormatter: { "\(Int($0)) bpm" }
        )
    }
}
