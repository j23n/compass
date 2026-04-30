import Foundation
import CompassData

/// Exports an `Activity`'s track points to a GPX 1.1 file.
public struct ActivityGPXExporter: Sendable {

    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Returns GPX 1.1 XML data for the given activity, or `nil` if it has no GPS track points.
    public static func export(activity: Activity, name: String? = nil) -> Data? {
        let sorted = activity.trackPoints
            .sorted { $0.timestamp < $1.timestamp }
            .filter { $0.latitude != 0 || $0.longitude != 0 }
        guard !sorted.isEmpty else { return nil }

        let trackName = (name ?? activity.sport.displayName)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Compass"
          xmlns="http://www.topografix.com/GPX/1/1"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd">
          <trk>
            <name>\(trackName)</name>
            <trkseg>
        """

        for point in sorted {
            let lat = String(format: "%.8f", point.latitude)
            let lon = String(format: "%.8f", point.longitude)
            xml += "\n      <trkpt lat=\"\(lat)\" lon=\"\(lon)\">"
            if let alt = point.altitude {
                xml += "\n        <ele>\(String(format: "%.1f", alt))</ele>"
            }
            xml += "\n        <time>\(iso8601.string(from: point.timestamp))</time>"
            xml += "\n      </trkpt>"
        }

        xml += """

            </trkseg>
          </trk>
        </gpx>
        """

        return xml.data(using: .utf8)
    }
}
