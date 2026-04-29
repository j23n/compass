import SwiftUI
import CompassData

/// A horizontal stacked bar showing sleep stage breakdown.
struct SleepStageBar: View {
    let stages: [SleepStage]

    private var totalDuration: TimeInterval {
        stages.reduce(0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
    }

    private var sortedStageGroups: [(type: SleepStageType, duration: TimeInterval)] {
        let grouped = Dictionary(grouping: stages, by: \.stage)
        return SleepStageType.allTypes.compactMap { stageType in
            guard let stagesForType = grouped[stageType] else { return nil }
            let duration = stagesForType.reduce(0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
            return (type: stageType, duration: duration)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Total duration label
            Text(formatDuration(totalDuration))
                .font(.headline)
                .foregroundStyle(.primary)

            // Stacked bar
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(Array(sortedStageGroups.enumerated()), id: \.offset) { index, group in
                        let fraction = totalDuration > 0
                            ? group.duration / totalDuration
                            : 0

                        RoundedRectangle(cornerRadius: barCornerRadius(
                            index: index,
                            total: sortedStageGroups.count
                        ))
                        .fill(colorForStage(group.type))
                        .frame(width: geometry.size.width * fraction)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .frame(height: 12)

            // Legend
            HStack(spacing: 16) {
                ForEach(sortedStageGroups, id: \.type) { group in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(colorForStage(group.type))
                            .frame(width: 8, height: 8)

                        Text(group.type.displayName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Text(formatDuration(group.duration))
                            .font(.caption2)
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
    }

    private func colorForStage(_ stage: SleepStageType) -> Color {
        switch stage {
        case .deep: .indigo
        case .rem: .purple
        case .light: Color(.systemGray4)
        case .awake: Color(.systemGray6)
        }
    }

    private func barCornerRadius(index: Int, total: Int) -> CGFloat {
        // The clip shape handles corner rounding, so inner segments are 0
        0
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}

// MARK: - Helpers

private extension SleepStageType {
    static var allTypes: [SleepStageType] {
        [.deep, .rem, .light, .awake]
    }
}

#Preview {
    let now = Date()
    let stages = [
        SleepStage(
            startDate: now.addingTimeInterval(-7 * 3600),
            endDate: now.addingTimeInterval(-5.5 * 3600),
            stage: .deep
        ),
        SleepStage(
            startDate: now.addingTimeInterval(-5.5 * 3600),
            endDate: now.addingTimeInterval(-4 * 3600),
            stage: .rem
        ),
        SleepStage(
            startDate: now.addingTimeInterval(-4 * 3600),
            endDate: now.addingTimeInterval(-1 * 3600),
            stage: .light
        ),
        SleepStage(
            startDate: now.addingTimeInterval(-1 * 3600),
            endDate: now.addingTimeInterval(-0.5 * 3600),
            stage: .awake
        ),
    ]

    return SleepStageBar(stages: stages)
        .padding()
}
