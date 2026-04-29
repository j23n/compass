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

/// Full-size interactive MapKit view showing a GPS route as a polyline.
struct MapRouteView: UIViewRepresentable {
    let coordinates: [CLLocationCoordinate2D]
    let pois: [MapPOI]

    init(trackPoints: [TrackPoint]) {
        let sorted = trackPoints.sorted { $0.timestamp < $1.timestamp }
        self.coordinates = sorted.compactMap { point in
            guard point.latitude != 0 || point.longitude != 0 else { return nil }
            return CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
        }
        self.pois = []
    }

    init(coordinates: [CLLocationCoordinate2D], pois: [MapPOI] = []) {
        self.coordinates = coordinates
        self.pois = pois
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

        if !pois.isEmpty {
            map.addAnnotations(pois.map { POIAnnotation(poi: $0) })
        }

        // Compute region around track AND POIs so off-route POIs aren't clipped.
        let allCoords = coordinates + pois.map(\.coordinate)
        let region = MKCoordinateRegion(routeCoordinates: allCoords, paddingFraction: 0.22)
        // Defer setRegion until after SwiftUI's layout pass has given the map view
        // its actual frame; calling it with a zero-frame produces "clip: empty path" warnings.
        if map.frame.isEmpty {
            DispatchQueue.main.async { map.setRegion(region, animated: false) }
        } else {
            map.setRegion(region, animated: false)
        }
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
                view.glyphImage = UIImage(systemName: poiSystemImage(forType: poi.poi.coursePointType))
                view.canShowCallout = true
                view.titleVisibility = .adaptive
                return view
            }
            return nil
        }

        private func poiSystemImage(forType type: Int) -> String {
            switch type {
            case 1: return "mountain.2.fill"          // summit
            case 2: return "arrow.down.to.line"       // valley
            case 3: return "drop.fill"                // water
            case 4: return "fork.knife"               // food
            case 5: return "exclamationmark.triangle" // danger
            case 6: return "arrow.turn.up.left"       // left
            case 7: return "arrow.turn.up.right"      // right
            case 8: return "arrow.up"                 // straight
            case 9: return "cross.fill"               // first_aid
            default: return "mappin"                  // generic
            }
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

final class POIAnnotation: NSObject, MKAnnotation {
    let poi: MapPOI
    var coordinate: CLLocationCoordinate2D { poi.coordinate }
    var title: String? { poi.name }

    init(poi: MapPOI) { self.poi = poi }
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
