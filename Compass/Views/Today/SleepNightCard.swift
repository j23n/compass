import SwiftUI
import CompassData

/// A summary card for the most recent sleep session: total duration, score,
/// timeline bar, and per-stage breakdown.
struct SleepNightCard: View {
    let session: SleepSession

    private var totalDuration: TimeInterval {
        session.endDate.timeIntervalSince(session.startDate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            durationLine
            SleepTimelineBar(stages: session.stages, height: 28)
            legend
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

    private var legend: some View {
        let durations = Dictionary(uniqueKeysWithValues:
            SleepStageColor.displayOrder.map { ($0, session.stages.duration(for: $0)) }
        )
        return HStack(spacing: 14) {
            ForEach(SleepStageColor.displayOrder, id: \.self) { stage in
                let dur = durations[stage] ?? 0
                if dur > 0 {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(SleepStageColor.color(for: stage))
                            .frame(width: 10, height: 10)
                        Text(stage.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(formatDuration(dur))
                            .font(.caption.weight(.semibold).monospacedDigit())
                    }
                }
            }
            Spacer(minLength: 0)
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
