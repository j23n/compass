import os

/// Centralized loggers for the Compass app layer.
/// Mirrors the BLELogger pattern from CompassBLE.
enum AppLogger {
    /// App lifecycle: launch, scene phase, container setup.
    static let app = Logger(subsystem: "com.compass.app", category: "app")

    /// Pairing flow: discovery, device selection, pair result.
    static let pairing = Logger(subsystem: "com.compass.app", category: "pairing")

    /// Sync orchestration: start, progress, parse, completion.
    static let sync = Logger(subsystem: "com.compass.app", category: "sync")

    /// UI events: navigation, user actions, sheet presentation.
    static let ui = Logger(subsystem: "com.compass.app", category: "ui")
}
