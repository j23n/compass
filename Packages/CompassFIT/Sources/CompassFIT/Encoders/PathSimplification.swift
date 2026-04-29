import Foundation

/// Ramer-Douglas-Peucker path simplification for GPS tracks.
public struct PathSimplification {

    /// Returns the indices (sorted) of points to keep from the input array.
    /// - Parameters:
    ///   - points: Array of (lat, lon) in decimal degrees.
    ///   - epsilon: Maximum perpendicular deviation in meters. Default 10 m.
    public static func simplify(
        points: [(lat: Double, lon: Double)],
        epsilon: Double = 10.0
    ) -> [Int] {
        guard points.count > 2 else { return Array(0..<points.count) }
        var kept = IndexSet([0, points.count - 1])
        rdp(points: points, start: 0, end: points.count - 1, epsilon: epsilon, kept: &kept)
        return kept.sorted()
    }

    // MARK: - Private

    private static func rdp(
        points: [(lat: Double, lon: Double)],
        start: Int,
        end: Int,
        epsilon: Double,
        kept: inout IndexSet
    ) {
        guard end - start > 1 else { return }

        var maxDist = 0.0
        var maxIdx = start

        for i in (start + 1)..<end {
            let d = perpendicularDistance(point: points[i], lineStart: points[start], lineEnd: points[end])
            if d > maxDist {
                maxDist = d
                maxIdx = i
            }
        }

        if maxDist > epsilon {
            kept.insert(maxIdx)
            rdp(points: points, start: start, end: maxIdx, epsilon: epsilon, kept: &kept)
            rdp(points: points, start: maxIdx, end: end, epsilon: epsilon, kept: &kept)
        }
    }

    /// Perpendicular distance from `point` to the great-circle chord A→B (metres).
    /// Uses Heron's formula on haversine side lengths — accurate for sub-km distances.
    private static func perpendicularDistance(
        point: (lat: Double, lon: Double),
        lineStart: (lat: Double, lon: Double),
        lineEnd: (lat: Double, lon: Double)
    ) -> Double {
        let dAB = haversineDistance(lat1: lineStart.lat, lon1: lineStart.lon, lat2: lineEnd.lat, lon2: lineEnd.lon)
        if dAB < 1e-9 {
            return haversineDistance(lat1: point.lat, lon1: point.lon, lat2: lineStart.lat, lon2: lineStart.lon)
        }
        let dAP = haversineDistance(lat1: lineStart.lat, lon1: lineStart.lon, lat2: point.lat, lon2: point.lon)
        let dPB = haversineDistance(lat1: point.lat, lon1: point.lon, lat2: lineEnd.lat, lon2: lineEnd.lon)
        let s = (dAB + dAP + dPB) / 2
        let areaSq = s * max(0, s - dAB) * max(0, s - dAP) * max(0, s - dPB)
        return 2 * areaSq.squareRoot() / dAB
    }
}

/// Haversine distance between two lat/lon points in metres (internal, shared across CompassFIT).
func haversineDistance(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
    let R = 6_371_000.0
    let dLat = (lat2 - lat1) * .pi / 180
    let dLon = (lon2 - lon1) * .pi / 180
    let a = sin(dLat / 2) * sin(dLat / 2) +
            cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) *
            sin(dLon / 2) * sin(dLon / 2)
    return R * 2 * atan2(sqrt(a), sqrt(1 - a))
}
