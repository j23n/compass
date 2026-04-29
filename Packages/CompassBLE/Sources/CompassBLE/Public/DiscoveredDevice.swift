import Foundation

/// A Garmin device discovered during BLE scanning.
///
/// This is a lightweight value type used during discovery. It contains only
/// the information available from the BLE advertisement (name, signal strength,
/// and the CoreBluetooth peripheral identifier).
///
/// To communicate with the device, pass it to ``GarminDeviceManager/pair(_:)``.
public struct DiscoveredDevice: Sendable, Hashable, Identifiable {
    /// The CoreBluetooth peripheral identifier (stable per device per phone).
    public let identifier: UUID

    /// The advertised device name (e.g., "Forerunner 265").
    public let name: String

    /// The received signal strength indicator in dBm. More negative = farther away.
    public let rssi: Int

    public var id: UUID { identifier }

    public init(identifier: UUID, name: String, rssi: Int) {
        self.identifier = identifier
        self.name = name
        self.rssi = rssi
    }
}
