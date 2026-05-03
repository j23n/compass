import SwiftUI
import Charts

/// A 24pt-tall time-anchored mini chart used in Today vitals chits.
/// The x-axis spans a fixed time window ending at `Date.now`, so the
/// right edge always represents "now" and old data slides off the left.
struct MiniWindowChart: View {
    enum Style {
        case line(color: Color)
        case bars(color: Color)
    }

    let samples: [(date: Date, value: Double)]
    let window: TimeInterval
    let style: Style

    var body: some View {
        let endDate = Date.now
        let startDate = endDate.addingTimeInterval(-window)
        let visible = samples.filter { $0.date >= startDate && $0.date <= endDate }

        Chart {
            switch style {
            case .line(let color):
                ForEach(visible, id: \.date) { s in
                    LineMark(x: .value("t", s.date), y: .value("v", s.value))
                        .foregroundStyle(color)
                        .interpolationMethod(.monotone)
                }
            case .bars(let color):
                ForEach(visible, id: \.date) { s in
                    BarMark(x: .value("t", s.date), y: .value("v", s.value))
                        .foregroundStyle(color)
                }
            }
        }
        .chartXScale(domain: startDate...endDate)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: 24)
    }
}
