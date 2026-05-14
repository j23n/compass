import SwiftUI
import MapKit
import CompassData

/// A point of interest to display on a `MapRouteView`.
struct MapPOI: Identifiable, Equatable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let name: String
    /// FIT `course_point` type enum (0=generic, 1=summit, 3=water, 4=food, 5=danger, 9=first_aid …).
    let coursePointType: Int

    static func == (lhs: MapPOI, rhs: MapPOI) -> Bool { lhs.id == rhs.id }
}

/// MapKit view showing a GPS route as a polyline.
///
/// Defaults to a static, non-interactive presentation (suitable for inline
/// previews). Pass `interactive: true` to enable pan/zoom — used by the
/// fullscreen expanded variant. Bumping `recenterToken` re-fits the camera
/// to the route bounds (used by the "recenter" toolbar button).
struct MapRouteView: UIViewRepresentable {
    let coordinates: [CLLocationCoordinate2D]
    let pois: [MapPOI]
    var highlightCoordinate: CLLocationCoordinate2D? = nil
    var interactive: Bool = false
    var recenterToken: Int = 0

    init(
        trackPoints: [TrackPoint],
        highlightCoordinate: CLLocationCoordinate2D? = nil,
        interactive: Bool = false,
        recenterToken: Int = 0
    ) {
        let sorted = trackPoints.sorted { $0.timestamp < $1.timestamp }
        self.coordinates = sorted.compactMap { point in
            guard point.latitude != 0 || point.longitude != 0 else { return nil }
            return CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
        }
        self.pois = []
        self.highlightCoordinate = highlightCoordinate
        self.interactive = interactive
        self.recenterToken = recenterToken
    }

    init(
        coordinates: [CLLocationCoordinate2D],
        pois: [MapPOI] = [],
        highlightCoordinate: CLLocationCoordinate2D? = nil,
        interactive: Bool = false,
        recenterToken: Int = 0
    ) {
        self.coordinates = coordinates
        self.pois = pois
        self.highlightCoordinate = highlightCoordinate
        self.interactive = interactive
        self.recenterToken = recenterToken
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.isScrollEnabled = interactive
        map.isZoomEnabled = interactive
        map.isRotateEnabled = interactive
        map.isPitchEnabled = interactive
        map.isUserInteractionEnabled = interactive
        map.showsUserLocation = false
        map.pointOfInterestFilter = .excludingAll
        map.delegate = context.coordinator
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coord = context.coordinator

        // Rebuild route when the coordinate set changes.
        if coord.lastCoordinateCount != coordinates.count {
            map.removeOverlays(map.overlays)
            let routeAnnotations = map.annotations.filter { !($0 is HighlightAnnotation) }
            map.removeAnnotations(routeAnnotations)

            guard !coordinates.isEmpty else {
                coord.lastCoordinateCount = 0
                return
            }

            let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
            map.addOverlay(polyline, level: .aboveRoads)

            map.addAnnotations([
                RouteAnnotation(coordinate: coordinates.first!, kind: .start),
                RouteAnnotation(coordinate: coordinates.last!, kind: .end),
            ])

            if !pois.isEmpty {
                map.addAnnotations(pois.map { POIAnnotation(poi: $0) })
            }

            applyInitialRegion(map: map)
            coord.lastCoordinateCount = coordinates.count
            coord.lastRecenterToken = recenterToken
        } else if coord.lastRecenterToken != recenterToken {
            // Recenter request from the host (e.g., toolbar button) without a
            // coordinate-set change — re-fit camera to the route bounds.
            applyInitialRegion(map: map, animated: true)
            coord.lastRecenterToken = recenterToken
        }

        // Update highlight annotation independently (fast path for chart scrubbing).
        if let existing = coord.highlightAnnotation {
            map.removeAnnotation(existing)
            coord.highlightAnnotation = nil
        }
        if let newCoord = highlightCoordinate {
            let ann = HighlightAnnotation(coordinate: newCoord)
            map.addAnnotation(ann)
            coord.highlightAnnotation = ann
        }
    }

    private func applyInitialRegion(map: MKMapView, animated: Bool = false) {
        let allCoords = coordinates + pois.map(\.coordinate)
        guard !allCoords.isEmpty else { return }
        let region = MKCoordinateRegion(routeCoordinates: allCoords, paddingFraction: 0.22)
        if map.frame.isEmpty {
            DispatchQueue.main.async { map.setRegion(region, animated: animated) }
        } else {
            map.setRegion(region, animated: animated)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {
        var lastCoordinateCount = 0
        var lastRecenterToken = 0
        var highlightAnnotation: HighlightAnnotation? = nil

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
            if let route = annotation as? RouteAnnotation {
                let view = MKMarkerAnnotationView(annotation: route, reuseIdentifier: route.kind.rawValue)
                view.markerTintColor = route.kind == .start ? .systemGreen : .systemRed
                view.glyphImage = UIImage(systemName: route.kind == .start ? "flag.fill" : "flag.checkered")
                view.canShowCallout = false
                return view
            }
            if let poi = annotation as? POIAnnotation {
                let view = MKMarkerAnnotationView(annotation: poi, reuseIdentifier: "POI")
                view.markerTintColor = .systemBlue
                let type = CoursePointType(fitCode: UInt8(clamping: poi.poi.coursePointType))
                view.glyphImage = UIImage(systemName: type.systemImage)
                view.canShowCallout = true
                view.titleVisibility = .adaptive
                return view
            }
            if annotation is HighlightAnnotation {
                let view = MKAnnotationView(annotation: annotation, reuseIdentifier: "highlight")
                view.bounds = CGRect(x: 0, y: 0, width: 14, height: 14)
                view.backgroundColor = .systemBlue
                view.layer.cornerRadius = 7
                view.layer.borderColor = UIColor.white.cgColor
                view.layer.borderWidth = 2.5
                view.layer.shadowColor = UIColor.black.cgColor
                view.layer.shadowOpacity = 0.3
                view.layer.shadowRadius = 2
                view.layer.shadowOffset = CGSize(width: 0, height: 1)
                view.canShowCallout = false
                return view
            }
            return nil
        }

    }
}

// MARK: - Annotations

final class RouteAnnotation: NSObject, MKAnnotation {
    enum Kind: String { case start, end }
    let coordinate: CLLocationCoordinate2D
    let kind: Kind

    init(coordinate: CLLocationCoordinate2D, kind: Kind) {
        self.coordinate = coordinate
        self.kind = kind
    }
}

final class POIAnnotation: NSObject, MKAnnotation {
    let poi: MapPOI
    var coordinate: CLLocationCoordinate2D { poi.coordinate }
    var title: String? { poi.name }

    init(poi: MapPOI) { self.poi = poi }
}

final class HighlightAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    init(coordinate: CLLocationCoordinate2D) { self.coordinate = coordinate }
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
