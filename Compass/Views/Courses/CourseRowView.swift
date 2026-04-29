import SwiftUI
import MapKit
import CompassData

/// A single row in the Courses list — sport icon, metadata, and map thumbnail.
struct CourseRowView: View {
    let course: Course

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
        Image(systemName: course.sport.systemImage)
            .font(.body)
            .foregroundStyle(course.sport.color)
            .frame(width: 42, height: 42)
            .background(course.sport.color.opacity(0.12))
            .clipShape(Circle())
    }

    private var infoStack: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(course.name)
                .font(.body)
                .fontWeight(.medium)
                .foregroundStyle(.primary)

            HStack(spacing: 4) {
                Text(course.importDate.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                separator
                Text(formattedDistance)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                separator
                Text(formattedDuration)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let ascent = course.totalAscent, ascent > 0 {
                    separator
                    Text(String(format: "↑%.0f m", ascent))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var mapThumbnail: some View {
        MapSnapshotView(coordinates: course.waypoints
            .sorted { $0.order < $1.order }
            .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        )
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(.separator), lineWidth: 0.5)
        }
        .overlay(alignment: .topTrailing) {
            if course.uploadedToWatch {
                Image(systemName: "applewatch.radiowaves.left.and.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(Color.blue, in: Circle())
                    .offset(x: 4, y: -4)
            }
        }
    }

    private var separator: some View {
        Text("·")
            .font(.caption)
            .foregroundStyle(.tertiary)
    }

    // MARK: - Formatting

    private var formattedDistance: String {
        let km = course.totalDistance / 1000.0
        return km >= 1 ? String(format: "%.1f km", km) : String(format: "%.0f m", course.totalDistance)
    }

    private var formattedDuration: String {
        let s = Int(course.estimatedDuration)
        let h = s / 3600
        let m = (s % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}
