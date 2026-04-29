import Foundation
import SwiftData

/// Represents a connected fitness device (e.g., Garmin watch).
@Model
public final class ConnectedDevice {
    #Unique<ConnectedDevice>([\.id])

    public var id: UUID
    public var name: String
    public var model: String
    public var lastSyncedAt: Date?
    public var fitFileCursor: Int
    /// CoreBluetooth peripheral identifier — stored at pair time so we can
    /// reconnect without re-scanning. Nil for devices paired before this field
    /// was added (user will need to re-pair once to populate it).
    public var peripheralIdentifier: UUID?

    public init(
        id: UUID = UUID(),
        name: String,
        model: String,
        lastSyncedAt: Date? = nil,
        fitFileCursor: Int = 0,
        peripheralIdentifier: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.model = model
        self.lastSyncedAt = lastSyncedAt
        self.fitFileCursor = fitFileCursor
        self.peripheralIdentifier = peripheralIdentifier
    }
}
