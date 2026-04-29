import SwiftUI
import Charts

/// Time range options for trend charts.
enum TrendTimeRange: String, CaseIterable, Identifiable {
    case week = "Week"
    case month = "Month"
    case threeMonths = "3 Mo"
    case year = "Year"

    var id: String { rawValue }
}

/// A data point for trend charts.
struct TrendDataPoint: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let value: Double
}

/// A reusable trend chart with time range picker and tap-to-inspect callout.
struct TrendChartView: View {
    let title: String
    var color: Color = .blue
    let data: [TrendDataPoint]
    var valueFormatter: @Sendable (Double) -> String = { String(format: "%.0f", $0) }

    @Binding var selectedRange: TrendTimeRange

    @State private var selectedDataPoint: TrendDataPoint?
    @State private var selectedXPosition: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            Picker("Time Range", selection: $selectedRange) {
                ForEach(TrendTimeRange.allCases) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .pickerStyle(.segmented)

            chartContent
                .frame(height: 200)
        }
    }

    @ViewBuilder
    private var chartContent: some View {
        Chart {
            ForEach(data) { point in
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

            if let selected = selectedDataPoint {
                RuleMark(x: .value("Selected", selected.date))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, spacing: 4) {
                        VStack(spacing: 2) {
                            Text(valueFormatter(selected.value))
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundStyle(.primary)
                            Text(selected.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
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
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
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
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                let xPosition = drag.location.x
                                guard let date: Date = proxy.value(atX: xPosition) else { return }
                                // Find nearest data point
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
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var range: TrendTimeRange = .week

        var body: some View {
            TrendChartView(
                title: "Resting Heart Rate",
                color: .red,
                data: sampleTrendData(),
                valueFormatter: { "\(Int($0)) bpm" },
                selectedRange: $range
            )
            .padding()
        }

        func sampleTrendData() -> [TrendDataPoint] {
            let calendar = Calendar.current
            let today = Date()
            return (0..<14).map { dayOffset in
                let date = calendar.date(byAdding: .day, value: -dayOffset, to: today)!
                let value = Double.random(in: 55...65)
                return TrendDataPoint(date: date, value: value)
            }.reversed()
        }
    }

    return PreviewWrapper()
}
