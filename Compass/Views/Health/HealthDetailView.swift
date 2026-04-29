import SwiftUI
import Charts

/// Fullscreen chart detail for a single health metric with drag-to-read interaction.
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

    private var minValue: Double { data.min(by: { $0.value < $1.value })?.value ?? 0 }
    private var maxValue: Double { data.max(by: { $0.value < $1.value })?.value ?? 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection
                chartSection
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
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 44, height: 44)
                .background(color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(selectedDataPoint.map { valueFormatter($0.value) }
                     ?? data.last.map { valueFormatter($0.value) }
                     ?? "--")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.15), value: selectedDataPoint?.id)

                if let pt = selectedDataPoint {
                    Text(pt.date, style: .date)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if !metricUnit.isEmpty {
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
                    Text("No \(metricTitle.lowercased()) data available.")
                }
                .frame(height: 300)
            } else {
                Chart {
                    ForEach(data) { point in
                        AreaMark(
                            x: .value("Date", point.date),
                            y: .value("Value", point.value)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [color.opacity(0.3), color.opacity(0.0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.catmullRom)

                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Value", point.value)
                        )
                        .foregroundStyle(color)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                    }

                    if let selected = selectedDataPoint {
                        RuleMark(x: .value("Selected", selected.date))
                            .foregroundStyle(Color.secondary.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .annotation(
                                position: .top,
                                spacing: 4,
                                overflowResolution: .init(x: .fit, y: .disabled)
                            ) {
                                callout(selected)
                            }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
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
                                        guard let date: Date = proxy.value(atX: drag.location.x) else { return }
                                        selectedDataPoint = data.min(by: {
                                            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
                                        })
                                    }
                                    .onEnded { _ in selectedDataPoint = nil }
                            )
                    }
                }
                .frame(height: 300)
            }
        }
    }

    private func callout(_ pt: TrendDataPoint) -> some View {
        VStack(spacing: 2) {
            Text(valueFormatter(pt.value))
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
            Text(pt.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.gray.opacity(0.2), lineWidth: 0.5)
        }
        .colorScheme(.light)
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
                        statItem(label: "Average", value: valueFormatter(averageValue))
                        statItem(label: "Min", value: valueFormatter(minValue))
                        statItem(label: "Max", value: valueFormatter(maxValue))
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
    private func statItem(label: String, value: String) -> some View {
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
    let sampleData: [TrendDataPoint] = (0..<14).map { offset in
        TrendDataPoint(
            date: Calendar.current.date(byAdding: .day, value: -offset, to: Date())!,
            value: Double.random(in: 55...68)
        )
    }.reversed()

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
