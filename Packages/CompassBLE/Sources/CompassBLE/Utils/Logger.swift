import os
import Foundation

/// Centralized loggers for the CompassBLE subsystem.
///
/// Each category maps to a layer in the BLE protocol stack. Messages are
/// prefixed with a high-resolution timestamp (`HH:mm:ss.SSS`) inside the
/// message text so they're visible no matter how the log is captured
/// (Xcode console, Console.app, `log show`, or any custom file sink).
enum BLELogger {
    static let transport = BLELoggerCategory(category: "transport")
    static let gfdi      = BLELoggerCategory(category: "gfdi")
    static let auth      = BLELoggerCategory(category: "auth")
    static let sync      = BLELoggerCategory(category: "sync")
}

/// Thin wrapper over `os.Logger` that prepends a wall-clock timestamp to
/// every message. Call sites use the same shape as `os.Logger`:
/// `BLELogger.transport.info("Connected to \(peripheral)")`.
struct BLELoggerCategory: Sendable {

    private let logger: Logger

    init(subsystem: String = "com.compass.ble", category: String) {
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    // MARK: - Public API

    func debug(_ message: String) {
        logger.debug("\(BLELoggerCategory.timestamp(), privacy: .public) \(message, privacy: .public)")
    }

    func info(_ message: String) {
        logger.info("\(BLELoggerCategory.timestamp(), privacy: .public) \(message, privacy: .public)")
    }

    func warning(_ message: String) {
        logger.warning("\(BLELoggerCategory.timestamp(), privacy: .public) \(message, privacy: .public)")
    }

    func error(_ message: String) {
        logger.error("\(BLELoggerCategory.timestamp(), privacy: .public) \(message, privacy: .public)")
    }

    // MARK: - Timestamp formatting

    /// Returns `HH:mm:ss.SSS` for the current wall clock. Lock-free, thread-safe.
    private static func timestamp() -> String {
        let now = Date().timeIntervalSince1970
        let secondsSinceEpoch = Int(now)
        let millis = Int((now - Double(secondsSinceEpoch)) * 1000.0)
        let secondsInDay = secondsSinceEpoch % 86_400
        let timezoneOffsetSeconds = TimeZone.current.secondsFromGMT()
        let local = (secondsInDay + timezoneOffsetSeconds + 86_400) % 86_400
        let h = local / 3600
        let m = (local % 3600) / 60
        let s = local % 60
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, millis)
    }
}
