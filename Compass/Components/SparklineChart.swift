import SwiftUI
import Charts

/// A minimal sparkline chart using Swift Charts — no axes, labels, or grid.
struct SparklineChart: View {
    let data: [Double]
    var color: Color = .red

    var body: some View {
        Chart {
            ForEach(Array(data.enumerated()), id: \.offset) { index, value in
                LineMark(
                    x: .value("Index", index),
                    y: .value("Value", value)
                )
                .foregroundStyle(color)
                .interpolationMethod(.catmullRom)

                AreaMark(
                    x: .value("Index", index),
                    y: .value("Value", value)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [color.opacity(0.3), color.opacity(0.0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
    }
}

#Preview {
    SparklineChart(
        data: [62, 58, 61, 59, 57, 60, 63, 58, 55, 59, 61, 60],
        color: .red
    )
    .frame(height: 40)
    .padding()
}
