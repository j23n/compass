import Foundation

/// A Garmin device that has been paired and authenticated.
///
/// Named `PairedDevice` (rather than `ConnectedDevice`) to avoid collision
/// with `CompassData.ConnectedDevice` in the app layer.
///
/// After pairing completes, the device's model string and product ID are
/// available from the GFDI device information exchange.
public struct PairedDevice: Sendable, Hashable, Identifiable, Codable {
    /// The CoreBluetooth peripheral identifier.
    public let identifier: UUID

    /// The advertised device name (e.g., "Forerunner 265").
    public let name: String

    /// The Garmin model string from the device information response.
    /// May be nil if the device information exchange hasn't completed.
    public let model: String?

    /// Garmin product number from DEVICE_INFORMATION (e.g. 3466 for Instinct Solar 1G).
    /// 0 means unknown.
    public let productID: UInt16

    public var id: UUID { identifier }

    public init(identifier: UUID, name: String, model: String?, productID: UInt16 = 0) {
        self.identifier = identifier
        self.name = name
        self.model = model
        self.productID = productID
    }
}
