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

    public init(
        id: UUID = UUID(),
        name: String,
        model: String,
        lastSyncedAt: Date? = nil,
        fitFileCursor: Int = 0
    ) {
        self.id = id
        self.name = name
        self.model = model
        self.lastSyncedAt = lastSyncedAt
        self.fitFileCursor = fitFileCursor
    }
}
