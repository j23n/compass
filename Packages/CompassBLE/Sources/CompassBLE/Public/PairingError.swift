import Foundation

/// Errors that can occur during Garmin BLE device discovery, pairing, and communication.
///
/// These map to the failure modes documented in the Garmin BLE protocol and observed
/// in Gadgetbridge's error handling paths.
public enum PairingError: Error, LocalizedError, Sendable {
    /// Bluetooth is powered off or the app lacks Bluetooth permission.
    case bluetoothUnavailable

    /// The requested device could not be found during scanning.
    case deviceNotFound

    /// The user rejected the pairing request on the watch.
    case pairingRejected

    /// The authentication handshake failed. The associated string contains details.
    case authenticationFailed(String)

    /// The connection attempt timed out before the watch responded.
    case connectionTimeout

    /// This code path is not yet implemented (stub).
    case notImplemented

    public var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable:
            return "Bluetooth is unavailable. Check that Bluetooth is enabled and the app has permission."
        case .deviceNotFound:
            return "The Garmin device could not be found. Make sure it is nearby and in pairing mode."
        case .pairingRejected:
            return "Pairing was rejected. Please accept the pairing request on your Garmin watch."
        case .authenticationFailed(let detail):
            return "Authentication failed: \(detail)"
        case .connectionTimeout:
            return "Connection timed out. Move closer to your Garmin device and try again."
        case .notImplemented:
            return "This feature is not yet implemented."
        }
    }
}
