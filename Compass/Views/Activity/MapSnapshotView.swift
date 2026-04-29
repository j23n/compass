import SwiftUI
import MapKit
import CompassData

/// Renders a static map thumbnail with the activity route drawn over it.
struct MapSnapshotView: View {
    private let coordinates: [CLLocationCoordinate2D]

    init(trackPoints: [TrackPoint]) {
        self.coordinates = trackPoints
            .sorted { $0.timestamp < $1.timestamp }
            .compactMap { point -> CLLocationCoordinate2D? in
                guard point.latitude != 0 || point.longitude != 0 else { return nil }
                return CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
            }
    }

    init(coordinates: [CLLocationCoordinate2D]) {
        self.coordinates = coordinates
    }

    @State private var snapshot: UIImage?

    var body: some View {
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
        }
        .task(id: coordinates.count) {
            snapshot = await generateSnapshot()
        }
    }

    // MARK: - Snapshot generation

    private func generateSnapshot() async -> UIImage? {
        let coords = coordinates
        guard !coords.isEmpty else { return nil }

        let options = MKMapSnapshotter.Options()
        options.size = CGSize(width: 120, height: 120)
        options.scale = UIScreen.main.scale
        options.mapType = .standard
        options.region = MKCoordinateRegion(routeCoordinates: coords, paddingFraction: 0.3)
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
            path.lineWidth = 2.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            UIColor.systemOrange.withAlphaComponent(0.9).setStroke()
            path.stroke()
        }
    }
}
