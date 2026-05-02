import SwiftUI
import SwiftData
import CompassData
import CompassBLE

/// Root view with tab navigation for the Compass app.
struct ContentView: View {
    var body: some View {
        TabView {
            Tab("Today", systemImage: "house.fill") {
                TodayView()
            }

            Tab("Activities", systemImage: "figure.run") {
                ActivitiesListView()
            }

            Tab("Health", systemImage: "heart.text.square.fill") {
                HealthView()
            }

            Tab("Courses", systemImage: "map") {
                CoursesListView()
            }
        }
    }
}

#Preview {
    let container = try! ModelContainer(
        for: ConnectedDevice.self, Activity.self, TrackPoint.self, SleepSession.self,
             SleepStage.self, HeartRateSample.self, HRVSample.self, BodyBatterySample.self,
             StressSample.self, StepCount.self, RespirationSample.self,
             Course.self, CourseWaypoint.self, CoursePOI.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    ContentView()
        .environment(SyncCoordinator(deviceManager: MockGarminDevice(), modelContainer: container))
        .modelContainer(container)
}
