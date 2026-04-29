import Foundation
import SwiftData

@MainActor
public final class DeviceRepository {
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    /// Fetches all connected devices, sorted by name.
    public func connectedDevices() throws -> [ConnectedDevice] {
        let descriptor = FetchDescriptor<ConnectedDevice>(
            sortBy: [SortDescriptor(\.name)]
        )
        return try context.fetch(descriptor)
    }

    /// Inserts or updates a device in the store.
    public func saveDevice(_ device: ConnectedDevice) throws {
        context.insert(device)
        try context.save()
    }

    /// Updates the FIT file sync cursor for the device with the given id.
    public func updateSyncCursor(deviceId: UUID, cursor: Int) throws {
        let predicate = #Predicate<ConnectedDevice> { device in
            device.id == deviceId
        }
        var descriptor = FetchDescriptor<ConnectedDevice>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let device = try context.fetch(descriptor).first else {
            return
        }
        device.fitFileCursor = cursor
        device.lastSyncedAt = Date()
        try context.save()
    }
}
