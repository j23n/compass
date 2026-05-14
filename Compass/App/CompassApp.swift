import SwiftUI
import SwiftData
import CompassData
import CompassBLE

@main
struct CompassApp: App {
    let container: ModelContainer
    @State private var syncCoordinator: SyncCoordinator
    @State private var importCoordinator = CourseImportCoordinator()
    @Environment(\.scenePhase) private var scenePhase

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
            SpO2Sample.self,
            IntensitySample.self,
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

        // Forward every BLE log entry into the shared in-app log store.
        BLELogger.sink = { level, category, message in
            let storeLevel = LogStore.Entry.Level(rawValue: level.rawValue) ?? .debug
            LogStore.shared.append(level: storeLevel, category: category, message: message)
        }

        // Always use the real device manager for BLE communication
        let deviceManager: any DeviceManagerProtocol = GarminDeviceManager()
        AppLogger.app.debug("Using GarminDeviceManager")

        _syncCoordinator = State(initialValue: SyncCoordinator(deviceManager: deviceManager, modelContainer: container))
        AppLogger.app.info("CompassApp initialization complete")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(syncCoordinator)
                .environment(importCoordinator)
                .modifier(CourseImportRouting(coordinator: importCoordinator))
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, newPhase in
            Task { await syncCoordinator.handleScenePhase(newPhase) }
        }
    }
}

/// Wires `.onOpenURL`, the duplicate-prompt sheet, and the import-error
/// alert onto the root scene content. Lives here (rather than directly on
/// the `WindowGroup` body) so it has access to the `\.modelContext`
/// environment provided by `.modelContainer`.
private struct CourseImportRouting: ViewModifier {
    let coordinator: CourseImportCoordinator
    @Environment(\.modelContext) private var modelContext

    func body(content: Content) -> some View {
        @Bindable var bindable = coordinator
        return content
            .onOpenURL { url in
                coordinator.handle(url: url, context: modelContext)
            }
            .sheet(item: $bindable.pendingImport) { pending in
                DuplicateImportSheet(pending: pending) { resolution in
                    coordinator.resolvePending(resolution, context: modelContext)
                }
            }
            .alert(
                "Import Failed",
                isPresented: Binding(
                    get: { coordinator.lastError != nil },
                    set: { if !$0 { coordinator.lastError = nil } }
                ),
                presenting: coordinator.lastError
            ) { _ in
                Button("OK") { coordinator.lastError = nil }
            } message: { error in
                Text(error)
            }
    }
}
