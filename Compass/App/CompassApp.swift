import SwiftUI
import SwiftData
import CompassData
import CompassBLE

@main
struct CompassApp: App {
    let container: ModelContainer
    @State private var syncCoordinator: SyncCoordinator

    init() {
        AppLogger.app.info("CompassApp initializing")

        let schema = Schema([
            Activity.self,
            TrackPoint.self,
            SleepSession.self,
            SleepStage.self,
            HeartRateSample.self,
            HRVSample.self,
            StressSample.self,
            BodyBatterySample.self,
            RespirationSample.self,
            StepCount.self,
            StepSample.self,
            ConnectedDevice.self,
            Course.self,
            CourseWaypoint.self,
            CoursePOI.self,
        ])

        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            container = try ModelContainer(for: schema, configurations: [config])
            AppLogger.app.info("ModelContainer created successfully")
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }

        // Always use the real device manager for BLE communication
        let deviceManager: any DeviceManagerProtocol = GarminDeviceManager()
        AppLogger.app.debug("Using GarminDeviceManager")

        _syncCoordinator = State(initialValue: SyncCoordinator(deviceManager: deviceManager))
        AppLogger.app.info("CompassApp initialization complete")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(syncCoordinator)
        }
        .modelContainer(container)
    }
}
