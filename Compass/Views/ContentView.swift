import SwiftUI
import SwiftData
import CompassData
import CompassBLE

/// Root view with tab navigation for the Compass app.
struct ContentView: View {
    @Environment(CourseImportCoordinator.self) private var importCoordinator
    @State private var selectedTab: TabSelection = .today

    enum TabSelection: Hashable { case today, activities, courses }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Today", systemImage: "house.fill", value: TabSelection.today) {
                TodayView()
            }

            Tab("Activities", systemImage: "figure.run", value: TabSelection.activities) {
                ActivitiesListView()
            }

            Tab("Courses", systemImage: "map", value: TabSelection.courses) {
                CoursesListView()
            }
        }
        // Auto-switch to Courses when an import completes. CoursesListView
        // then consumes `lastImportedCourse` to push the detail view; we
        // only own the tab-selection side of that hand-off here.
        .onChange(of: importCoordinator.lastImportedCourse) { _, course in
            if course != nil { selectedTab = .courses }
        }
    }
}

#Preview {
    let container = try! ModelContainer(
        for: ConnectedDevice.self, Activity.self, TrackPoint.self, SleepSession.self,
             SleepStage.self, HeartRateSample.self, HRVSample.self, BodyBatterySample.self,
             StressSample.self, StepCount.self, RespirationSample.self, SpO2Sample.self,
             Course.self, CourseWaypoint.self, CoursePOI.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    ContentView()
        .environment(SyncCoordinator(deviceManager: MockGarminDevice(), modelContainer: container))
        .environment(CourseImportCoordinator())
        .modelContainer(container)
}
