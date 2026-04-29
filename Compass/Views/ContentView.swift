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

            Tab("Health", systemImage: "heart.text.square.fill") {
                HealthView()
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(SyncCoordinator(deviceManager: MockGarminDevice()))
        .modelContainer(for: [
            ConnectedDevice.self,
            Activity.self,
            TrackPoint.self,
            SleepSession.self,
            SleepStage.self,
            HeartRateSample.self,
            HRVSample.self,
            BodyBatterySample.self,
            StressSample.self,
            StepCount.self,
            RespirationSample.self,
        ], inMemory: true)
}
