import Foundation
import os

/// Centralized loggers for the Compass app layer.
/// Mirrors the BLELoggerCategory pattern from CompassBLE — each message is
/// prefixed with a wall-clock timestamp (`HH:mm:ss.SSS`) so it's readable
/// regardless of how the log is captured (Xcode console, Console.app, `log show`).
enum AppLogger {
    /// App lifecycle: launch, scene phase, container setup.
    static let app      = AppLoggerCategory(category: "app")

    /// Pairing flow: discovery, device selection, pair result.
    static let pairing  = AppLoggerCategory(category: "pairing")

    /// Sync orchestration: start, progress, parse, completion.
    static let sync     = AppLoggerCategory(category: "sync")

    /// UI events: navigation, user actions, sheet presentation.
    static let ui       = AppLoggerCategory(category: "ui")

    /// Watch services: weather, find-my-phone, music remote.
    static let services = AppLoggerCategory(category: "services")

    /// Phone location pushes to the watch.
    static let location = AppLoggerCategory(category: "location")

    /// Apple Health export pipeline.
    static let health   = AppLoggerCategory(category: "health")
}

/// Thin wrapper over `os.Logger` that prepends a wall-clock timestamp to
/// every message. Call sites use the same shape as `os.Logger`:
/// `AppLogger.sync.info("Connected to \(device)")`.
struct AppLoggerCategory: Sendable {

    private let logger: Logger
    let category: String

    init(subsystem: String = "com.compass.app", category: String) {
        self.logger = Logger(subsystem: subsystem, category: category)
        self.category = category
    }

    func debug(_ message: String) {
        logger.debug("\(AppLoggerCategory.timestamp(), privacy: .public) \(message, privacy: .public)")
        LogStore.shared.append(level: .debug, category: category, message: message)
    }

    func info(_ message: String) {
        logger.info("\(AppLoggerCategory.timestamp(), privacy: .public) \(message, privacy: .public)")
        LogStore.shared.append(level: .info, category: category, message: message)
    }

    func warning(_ message: String) {
        logger.warning("\(AppLoggerCategory.timestamp(), privacy: .public) \(message, privacy: .public)")
        LogStore.shared.append(level: .warning, category: category, message: message)
    }

    func error(_ message: String) {
        logger.error("\(AppLoggerCategory.timestamp(), privacy: .public) \(message, privacy: .public)")
        LogStore.shared.append(level: .error, category: category, message: message)
    }

    private static func timestamp() -> String {
        let now = Date().timeIntervalSince1970
        let secondsSinceEpoch = Int(now)
        let millis = Int((now - Double(secondsSinceEpoch)) * 1000.0)
        let secondsInDay = secondsSinceEpoch % 86_400
        let tzOffset = TimeZone.current.secondsFromGMT()
        let local = (secondsInDay + tzOffset + 86_400) % 86_400
        let h = local / 3600
        let m = (local % 3600) / 60
        let s = local % 60
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, millis)
    }
}
