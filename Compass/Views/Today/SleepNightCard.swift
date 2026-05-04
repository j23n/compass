import SwiftUI
import CompassData

/// A summary card for the most recent sleep session: total duration, score,
/// timeline bar, and per-stage breakdown.
struct SleepNightCard: View {
    let session: SleepSession

    private var totalDuration: TimeInterval {
        session.endDate.timeIntervalSince(session.startDate)
    }

    private var visibleStages: [SleepStage] { session.trimmedStages }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            durationLine
            barAndLegend
        }
        .padding(16)
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

    private var header: some View {
        HStack {
            Label("Sleep", systemImage: "bed.double.fill")
                .font(.headline)
                .foregroundStyle(.purple)
            Spacer()
            Text(session.startDate, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var durationLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(formatDuration(totalDuration))
                .font(.title2.bold())
            if let score = session.score {
                Text("score \(score)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(timeFmt(session.startDate)) – \(timeFmt(session.endDate))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var barAndLegend: some View {
        HStack(alignment: .center, spacing: 14) {
            SleepTimelineBar(stages: visibleStages, height: 56)
                .frame(maxWidth: .infinity)
            legend
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var legend: some View {
        let durations = Dictionary(uniqueKeysWithValues:
            SleepStageColor.displayOrder.map { ($0, visibleStages.duration(for: $0)) }
        )
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(SleepStageColor.displayOrder, id: \.self) { stage in
                let dur = durations[stage] ?? 0
                if dur > 0 {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(SleepStageColor.color(for: stage))
                            .frame(width: 8, height: 8)
                        Text(stage.displayName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(formatDuration(dur))
                            .font(.caption2.weight(.semibold).monospacedDigit())
                    }
                }
            }
        }
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private func timeFmt(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }
}
