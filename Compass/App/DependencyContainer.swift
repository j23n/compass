import Foundation
import CompassBLE

/// Simple dependency container using protocol-typed dependencies.
/// Passed via initializer injection -- no singletons or service locators.
struct DependencyContainer: Sendable {
    let deviceManager: any DeviceManagerProtocol

    static func createDefault() -> DependencyContainer {
        AppLogger.app.debug("DependencyContainer: creating with GarminDeviceManager")
        return DependencyContainer(deviceManager: GarminDeviceManager())
    }
}
