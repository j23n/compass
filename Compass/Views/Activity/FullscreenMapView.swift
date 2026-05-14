import SwiftUI
import MapKit

/// Full-screen interactive map presented when the user taps an inline route
/// preview. Wraps `MapRouteView(interactive: true)` plus a close button and
/// a recenter button. Used by both `CourseDetailView` and `ActivityDetailView`.
struct FullscreenMapView: View {
    let coordinates: [CLLocationCoordinate2D]
    let pois: [MapPOI]
    let title: String

    @Environment(\.dismiss) private var dismiss
    @State private var recenterToken: Int = 0

    init(coordinates: [CLLocationCoordinate2D], pois: [MapPOI] = [], title: String) {
        self.coordinates = coordinates
        self.pois = pois
        self.title = title
    }

    var body: some View {
        NavigationStack {
            MapRouteView(
                coordinates: coordinates,
                pois: pois,
                interactive: true,
                recenterToken: recenterToken
            )
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        recenterToken &+= 1
                    } label: {
                        Image(systemName: "scope")
                    }
                    .accessibilityLabel("Recenter")
                }
            }
        }
    }
}
