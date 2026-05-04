import SwiftUI
import CompassData

/// A single row in the Activities list — sport icon, metadata, and map thumbnail.
struct ActivityRowView: View {
    let activity: Activity

    var body: some View {
        HStack(spacing: 12) {
            sportIcon
            infoStack
            Spacer(minLength: 0)
            mapThumbnail
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    // MARK: - Subviews

    private var sportIcon: some View {
        Image(systemName: activity.sport.systemImage)
            .font(.body)
            .foregroundStyle(activity.sport.color)
            .frame(width: 42, height: 42)
            .background(activity.sport.color.opacity(0.12))
            .clipShape(Circle())
    }

    private var infoStack: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(activity.sport.displayName)
                .font(.body)
                .fontWeight(.medium)
                .foregroundStyle(.primary)

            HStack(spacing: 4) {
                Text(activity.startDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if activity.distance > 0 {
                    separator
                    Text(formattedDistance)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                separator
                Text(formattedDuration)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var mapThumbnail: some View {
        MapSnapshotView(
            trackPoints: activity.trackPoints,
            cacheKey: "activity_\(activity.id.uuidString)_thumb"
        )
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(.separator), lineWidth: 0.5)
            }
    }

    private var separator: some View {
        Text("·")
            .font(.caption)
            .foregroundStyle(.tertiary)
    }

    // MARK: - Formatting

    private var formattedDistance: String {
        let km = activity.distance / 1000.0
        return km >= 1 ? String(format: "%.2f km", km) : String(format: "%.0f m", activity.distance)
    }

    private var formattedDuration: String {
        let h = Int(activity.duration) / 3600
        let m = (Int(activity.duration) % 3600) / 60
        let s = Int(activity.duration) % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
