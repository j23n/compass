import SwiftUI
import Charts

/// A reusable card for displaying a metric with an optional sparkline chart.
struct MetricCard: View {
    let title: String
    let value: String
    var unit: String? = nil
    var color: Color = .primary
    var icon: String = "heart.fill"
    var sparklineData: [Double]? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .font(.subheadline)

                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)

                if let unit {
                    Text(unit)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            if let sparklineData, !sparklineData.isEmpty {
                SparklineChart(data: sparklineData, color: color)
                    .frame(height: 40)
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
    VStack(spacing: 16) {
        MetricCard(
            title: "Resting Heart Rate",
            value: "58",
            unit: "bpm",
            color: .red,
            icon: "heart.fill",
            sparklineData: [62, 58, 61, 59, 57, 60, 63, 58, 55, 59, 61, 60]
        )

        MetricCard(
            title: "Steps",
            value: "8,432",
            color: .green,
            icon: "figure.walk"
        )
    }
    .padding()
}
