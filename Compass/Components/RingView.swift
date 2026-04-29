import SwiftUI

/// A single animated circular progress ring with an icon and label.
struct RingView: View {
    let progress: Double
    var lineWidth: CGFloat = 12
    var color: Color = .green
    var icon: String = "flame.fill"
    var label: String = ""
    var valueText: String = ""

    @State private var animatedProgress: Double = 0

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                // Track
                Circle()
                    .stroke(
                        color.opacity(0.2),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )

                // Progress arc
                Circle()
                    .trim(from: 0, to: animatedProgress)
                    .stroke(
                        color,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                // Center icon
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color)
                    .fontWeight(.semibold)
            }
            .aspectRatio(1, contentMode: .fit)

            if !valueText.isEmpty {
                Text(valueText)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            if !label.isEmpty {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .onAppear {
            withAnimation(.spring(duration: 1.0, bounce: 0.3)) {
                animatedProgress = min(max(progress, 0), 1)
            }
        }
        .onChange(of: progress) { _, newValue in
            withAnimation(.spring(duration: 0.6, bounce: 0.2)) {
                animatedProgress = min(max(newValue, 0), 1)
            }
        }
    }
}

#Preview {
    HStack(spacing: 24) {
        RingView(
            progress: 0.75,
            color: .green,
            icon: "figure.walk",
            label: "Activity",
            valueText: "45 min"
        )
        .frame(width: 120)

        RingView(
            progress: 0.6,
            color: .purple,
            icon: "bed.double.fill",
            label: "Sleep",
            valueText: "7.2 hr"
        )
        .frame(width: 120)
    }
    .padding()
}
