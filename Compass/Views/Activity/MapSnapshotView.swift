import SwiftUI
import MapKit
import CompassData

/// Renders a static map thumbnail with the activity route drawn over it.
///
/// When a `cacheKey` is provided the rendered image is reused from the shared
/// `MapSnapshotCache` (memory + on-disk) — keyed by `cacheKey` plus the requested
/// pixel size, so the same activity rendered at thumbnail and detail sizes does
/// not collide. An optional `highlightCoordinate` overlays a SwiftUI dot at the
/// linearly-projected pixel position, used by the activity detail view's chart
/// scrubbing.
struct MapSnapshotView: View {
    private let coordinates: [CLLocationCoordinate2D]
    /// Pixel size of the rendered snapshot (logical points; scale applied internally).
    private let size: CGSize
    /// Stable identifier for caching. `nil` disables caching entirely.
    private let cacheKey: String?
    /// Coordinate to highlight with a SwiftUI dot overlay, e.g. for chart scrubbing.
    private let highlightCoordinate: CLLocationCoordinate2D?

    init(
        trackPoints: [TrackPoint],
        size: CGSize = CGSize(width: 120, height: 120),
        cacheKey: String? = nil,
        highlightCoordinate: CLLocationCoordinate2D? = nil
    ) {
        self.coordinates = trackPoints
            .sorted { $0.timestamp < $1.timestamp }
            .compactMap { point -> CLLocationCoordinate2D? in
                guard point.latitude != 0 || point.longitude != 0 else { return nil }
                return CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
            }
        self.size = size
        self.cacheKey = cacheKey
        self.highlightCoordinate = highlightCoordinate
    }

    init(
        coordinates: [CLLocationCoordinate2D],
        size: CGSize = CGSize(width: 120, height: 120),
        cacheKey: String? = nil,
        highlightCoordinate: CLLocationCoordinate2D? = nil
    ) {
        self.coordinates = coordinates
        self.size = size
        self.cacheKey = cacheKey
        self.highlightCoordinate = highlightCoordinate
    }

    @State private var snapshot: UIImage?

    /// Region computed deterministically from the input coordinates — must match
    /// what the snapshotter used so highlight overlays land in the right pixel.
    private var region: MKCoordinateRegion? {
        guard !coordinates.isEmpty else { return nil }
        return MKCoordinateRegion(routeCoordinates: coordinates, paddingFraction: 0.3)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let snapshot {
                    Image(uiImage: snapshot)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Color(.systemGray5)
                        Image(systemName: "map")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let coord = highlightCoordinate,
                   let region,
                   let pos = pixelPosition(for: coord, region: region, in: geo.size) {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Color.white, lineWidth: 2.5))
                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                        .position(pos)
                }
            }
        }
        .task(id: cacheKey ?? "ephemeral-\(coordinates.count)") {
            await loadSnapshot()
        }
    }

    // MARK: - Snapshot generation

    private func loadSnapshot() async {
        guard !coordinates.isEmpty else { return }

        let key = cacheKey.map { fullCacheKey(base: $0) }
        if let key, let cached = await MapSnapshotCache.shared.image(forKey: key) {
            snapshot = cached
            return
        }

        guard let generated = await generateSnapshot() else { return }
        snapshot = generated
        if let key {
            MapSnapshotCache.shared.setImage(generated, forKey: key)
        }
    }

    private func fullCacheKey(base: String) -> String {
        let scale = Int(UIScreen.main.scale)
        return "\(base)_\(Int(size.width))x\(Int(size.height))@\(scale)"
    }

    private func generateSnapshot() async -> UIImage? {
        guard let region else { return nil }
        let coords = coordinates

        let options = MKMapSnapshotter.Options()
        options.size = size
        options.scale = UIScreen.main.scale
        options.mapType = .standard
        options.region = region
        options.pointOfInterestFilter = .excludingAll

        let snapshotter = MKMapSnapshotter(options: options)
        do {
            let result = try await snapshotter.start()
            return drawRoute(on: result, coords: coords)
        } catch {
            return nil
        }
    }

    private func drawRoute(on result: MKMapSnapshotter.Snapshot, coords: [CLLocationCoordinate2D]) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: result.image.size)
        return renderer.image { _ in
            result.image.draw(at: .zero)

            let path = UIBezierPath()
            let points = coords.map { result.point(for: $0) }
            guard let first = points.first else { return }
            path.move(to: first)
            for pt in points.dropFirst() { path.addLine(to: pt) }
            path.lineWidth = max(2.5, size.width / 160)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            UIColor.systemOrange.withAlphaComponent(0.9).setStroke()
            path.stroke()
        }
    }

    // MARK: - Highlight projection

    /// Linear lat/lon → pixel projection. Activity routes are small enough that
    /// the Mercator distortion vs. MKMapView's projection is well under a pixel.
    private func pixelPosition(
        for coord: CLLocationCoordinate2D,
        region: MKCoordinateRegion,
        in viewSize: CGSize
    ) -> CGPoint? {
        let minLat = region.center.latitude  - region.span.latitudeDelta  / 2
        let maxLat = region.center.latitude  + region.span.latitudeDelta  / 2
        let minLon = region.center.longitude - region.span.longitudeDelta / 2
        let maxLon = region.center.longitude + region.span.longitudeDelta / 2
        guard maxLat > minLat, maxLon > minLon else { return nil }
        let xRatio = (coord.longitude - minLon) / (maxLon - minLon)
        let yRatio = (maxLat - coord.latitude) / (maxLat - minLat)
        guard (0...1).contains(xRatio), (0...1).contains(yRatio) else { return nil }
        return CGPoint(x: xRatio * viewSize.width, y: yRatio * viewSize.height)
    }
}
