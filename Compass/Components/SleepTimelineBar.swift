import SwiftUI
import CompassData

/// Color palette shared by every sleep visualization.
enum SleepStageColor {
    static func color(for stage: SleepStageType) -> Color {
        switch stage {
        case .deep:  .indigo
        case .rem:   .purple
        case .light: Color(.systemTeal).opacity(0.55)
        case .awake: Color(.systemGray3)
        }
    }

    /// Display order: deep → rem → light → awake. Used by stacked bars and legends.
    static let displayOrder: [SleepStageType] = [.deep, .rem, .light, .awake]
}

/// A horizontal timeline bar where each `SleepStage` becomes a colored segment
/// proportional to its duration, in chronological order.
struct SleepTimelineBar: View {
    let stages: [SleepStage]
    var height: CGFloat = 24
    var cornerRadius: CGFloat = 6

    var body: some View {
        let sorted = stages.sorted { $0.startDate < $1.startDate }
        let total = sorted.reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }

        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(sorted.enumerated()), id: \.offset) { _, stage in
                    let dur = stage.endDate.timeIntervalSince(stage.startDate)
                    let frac = total > 0 ? dur / total : 0
                    Rectangle()
                        .fill(SleepStageColor.color(for: stage.stage))
                        .frame(width: geo.size.width * frac)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .frame(height: height)
    }
}

// MARK: - Helpers

extension Array where Element == SleepStage {
    /// Total duration spent in `stageType` across this stage array.
    func duration(for stageType: SleepStageType) -> TimeInterval {
        reduce(0) { sum, stage in
            stage.stage == stageType
                ? sum + stage.endDate.timeIntervalSince(stage.startDate)
                : sum
        }
    }
}
