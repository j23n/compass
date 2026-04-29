import SwiftUI
import MapKit
import CompassData

/// Full-size interactive MapKit view showing a GPS route as a polyline.
struct MapRouteView: UIViewRepresentable {
    let coordinates: [CLLocationCoordinate2D]

    init(trackPoints: [TrackPoint]) {
        let sorted = trackPoints.sorted { $0.timestamp < $1.timestamp }
        self.coordinates = sorted.compactMap { point in
            guard point.latitude != 0 || point.longitude != 0 else { return nil }
            return CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
        }
    }

    init(coordinates: [CLLocationCoordinate2D]) {
        self.coordinates = coordinates
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.isScrollEnabled = false
        map.isZoomEnabled = false
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.isUserInteractionEnabled = false
        map.showsUserLocation = false
        map.pointOfInterestFilter = .excludingAll
        map.delegate = context.coordinator
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations)

        guard !coordinates.isEmpty else { return }

        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        map.addOverlay(polyline, level: .aboveRoads)

        map.addAnnotations([
            RouteAnnotation(coordinate: coordinates.first!, kind: .start),
            RouteAnnotation(coordinate: coordinates.last!, kind: .end),
        ])

        map.setRegion(
            MKCoordinateRegion(routeCoordinates: coordinates, paddingFraction: 0.22),
            animated: false
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let r = MKPolylineRenderer(polyline: polyline)
            r.strokeColor = UIColor.systemOrange
            r.lineWidth = 4
            r.lineCap = .round
            r.lineJoin = .round
            return r
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            guard let route = annotation as? RouteAnnotation else { return nil }
            let view = MKMarkerAnnotationView(annotation: route, reuseIdentifier: route.kind.rawValue)
            view.markerTintColor = route.kind == .start ? .systemGreen : .systemRed
            view.glyphImage = UIImage(systemName: route.kind == .start ? "flag.fill" : "flag.checkered")
            view.canShowCallout = false
            return view
        }
    }
}

// MARK: - Route annotation

final class RouteAnnotation: NSObject, MKAnnotation {
    enum Kind: String { case start, end }
    let coordinate: CLLocationCoordinate2D
    let kind: Kind

    init(coordinate: CLLocationCoordinate2D, kind: Kind) {
        self.coordinate = coordinate
        self.kind = kind
    }
}

// MARK: - MKCoordinateRegion convenience

extension MKCoordinateRegion {
    init(routeCoordinates coords: [CLLocationCoordinate2D], paddingFraction: Double = 0.15) {
        let lats = coords.map(\.latitude)
        let lons = coords.map(\.longitude)
        let minLat = lats.min()!, maxLat = lats.max()!
        let minLon = lons.min()!, maxLon = lons.max()!
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let latSpan = max((maxLat - minLat) * (1 + paddingFraction * 2), 0.005)
        let lonSpan = max((maxLon - minLon) * (1 + paddingFraction * 2), 0.005)
        self.init(center: center, span: MKCoordinateSpan(latitudeDelta: latSpan, longitudeDelta: lonSpan))
    }
}
