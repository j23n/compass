import SwiftUI

/// A single stat display cell used in hero stats grids.
struct StatCell: View {
    let title: String
    let value: String
    var unit: String? = nil

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                if let unit {
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
    }
}

#Preview {
    Grid(horizontalSpacing: 12, verticalSpacing: 12) {
        GridRow {
            StatCell(title: "Distance", value: "5.23", unit: "km")
            StatCell(title: "Time", value: "28:45")
        }
        GridRow {
            StatCell(title: "Pace", value: "5:30", unit: "/km")
            StatCell(title: "Avg HR", value: "156", unit: "bpm")
        }
    }
    .padding()
}
