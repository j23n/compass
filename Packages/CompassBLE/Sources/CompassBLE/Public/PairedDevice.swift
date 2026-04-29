import Foundation

/// A Garmin device that has been paired and authenticated.
///
/// Named `PairedDevice` (rather than `ConnectedDevice`) to avoid collision
/// with `CompassData.ConnectedDevice` in the app layer.
///
/// After pairing completes, the device's model string is available from the
/// GFDI device information exchange.
public struct PairedDevice: Sendable, Hashable, Identifiable, Codable {
    /// The CoreBluetooth peripheral identifier.
    public let identifier: UUID

    /// The advertised device name (e.g., "Forerunner 265").
    public let name: String

    /// The Garmin model string from the device information response.
    /// May be nil if the device information exchange hasn't completed.
    public let model: String?

    public var id: UUID { identifier }

    public init(identifier: UUID, name: String, model: String?) {
        self.identifier = identifier
        self.name = name
        self.model = model
    }
}
