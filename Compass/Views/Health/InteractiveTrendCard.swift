import SwiftUI
import Charts

/// A health metric card with a polished chart and drag-to-read interaction.
/// The card header is a NavigationLink to the full detail view;
/// the chart area handles drag independently so both coexist cleanly.
struct InteractiveTrendCard: View {
    let title: String
    let icon: String
    let color: Color
    let unit: String
    let data: [TrendDataPoint]
    var useBarChart: Bool = false
    var selectedRange: TrendTimeRange = .week
    let valueFormatter: @Sendable (Double) -> String

    @State private var selectedPoint: TrendDataPoint?

    private var displayValue: String {
        if let pt = selectedPoint { return valueFormatter(pt.value) }
        if let last = data.last { return valueFormatter(last.value) }
        return "--"
    }

    private var barUnit: Calendar.Component { selectedRange == .year ? .month : .day }

    private var axisDesiredCount: Int {
        switch selectedRange {
        case .day:   return 6
        case .week:  return 7
        case .month: return 6
        case .year:  return 12
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Tappable header — navigates to HealthDetailView
            NavigationLink {
                HealthDetailView(
                    metricTitle: title,
                    metricUnit: unit,
                    color: color,
                    icon: icon,
                    data: data,
                    useBarChart: useBarChart,
                    initialRange: selectedRange,
                    valueFormatter: valueFormatter
                )
            } label: {
                cardHeader
            }
            .buttonStyle(.plain)

            Divider()
                .padding(.vertical, 10)

            if data.isEmpty {
                emptyChart
            } else {
                chartView
                    .frame(height: 120)
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

    // MARK: - Header

    private var cardHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(color)

            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.primary)

            Spacer()

            Text(displayValue)
                .font(.subheadline)
                .foregroundStyle(selectedPoint != nil ? color : .secondary)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.15), value: selectedPoint?.id)

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Chart

    @ViewBuilder
    private var chartView: some View {
        Chart {
            if useBarChart {
                ForEach(data) { point in
                    BarMark(
                        x: .value("Date", point.date, unit: barUnit),
                        y: .value("Value", point.value)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [color.opacity(0.85), color.opacity(0.45)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .cornerRadius(3)
                }
            } else {
                ForEach(data) { point in
                    PointMark(
                        x: .value("Date", point.date),
                        y: .value("Value", point.value)
                    )
                    .foregroundStyle(color.opacity(0.75))
                    .symbolSize(25)
                }
            }

            if let pt = selectedPoint {
                RuleMark(x: .value("Selected", pt.date))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit, y: .disabled)) {
                        callout(pt)
                    }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: axisDesiredCount)) { _ in
                AxisValueLabel(format: xAxisFormat)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
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
                                selectedPoint = data.min(by: {
                                    abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
                                })
                            }
                            .onEnded { _ in selectedPoint = nil }
                    )
            }
        }
    }

    private var xAxisFormat: Date.FormatStyle {
        switch selectedRange {
        case .day:         return .dateTime.hour()
        case .week, .month: return .dateTime.month(.abbreviated).day()
        case .year:        return .dateTime.month(.abbreviated)
        }
    }

    private func callout(_ pt: TrendDataPoint) -> some View {
        let dateFormat: Date.FormatStyle = {
            switch selectedRange {
            case .day:         return .dateTime.hour().minute()
            case .week, .month: return .dateTime.month(.abbreviated).day()
            case .year:        return .dateTime.month(.abbreviated).year()
            }
        }()
        return VStack(spacing: 2) {
            Text(valueFormatter(pt.value))
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
            Text(pt.date, format: dateFormat)
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

    private var emptyChart: some View {
        Text("No data available")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
    }
}
