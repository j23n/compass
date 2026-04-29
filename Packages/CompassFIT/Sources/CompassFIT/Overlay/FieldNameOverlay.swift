import Foundation
import os

// MARK: - Resolved overlay types used at runtime

/// A resolved overlay definition ready for field name lookups.
public struct OverlayDefinition: Sendable {
    /// Message overlays keyed by global message number.
    public let messages: [UInt16: MessageOverlay]

    public init(messages: [UInt16: MessageOverlay]) {
        self.messages = messages
    }
}

/// Overlay for a single message type.
public struct MessageOverlay: Sendable {
    public let name: String
    /// Field overlays keyed by field definition number.
    public let fields: [UInt8: FieldOverlay]

    public init(name: String, fields: [UInt8: FieldOverlay]) {
        self.name = name
        self.fields = fields
    }
}

/// Overlay for a single field.
public struct FieldOverlay: Sendable {
    public let name: String
    public let type: String
    public let units: String

    public init(name: String, type: String, units: String) {
        self.name = name
        self.type = type
        self.units = units
    }
}

// MARK: - Enriched message produced after applying the overlay

/// A FIT message enriched with human-readable field names from the overlay.
public struct EnrichedFITMessage: Sendable {
    public let globalMessageNumber: UInt16
    public let messageName: String?
    public let fields: [EnrichedField]

    public init(globalMessageNumber: UInt16, messageName: String?, fields: [EnrichedField]) {
        self.globalMessageNumber = globalMessageNumber
        self.messageName = messageName
        self.fields = fields
    }
}

/// A single field enriched with its overlay name and units.
public struct EnrichedField: Sendable {
    public let fieldNumber: UInt8
    public let name: String?
    public let units: String?
    public let value: FITFieldValue

    public init(fieldNumber: UInt8, name: String?, units: String?, value: FITFieldValue) {
        self.fieldNumber = fieldNumber
        self.name = name
        self.units = units
        self.value = value
    }
}

// MARK: - FieldNameOverlay loader

/// Thread-safe, lazily-loaded overlay that enriches raw FIT data with human-readable field names.
public final class FieldNameOverlay: Sendable {

    private static let logger = Logger(subsystem: "com.compass.fit", category: "FieldNameOverlay")

    /// Lazily loaded overlay definition. Nonisolated(unsafe) is safe because we
    /// initialise it exactly once behind an os_unfair_lock.
    private nonisolated(unsafe) var _cachedOverlay: OverlayDefinition?
    private let lock = OSAllocatedUnfairLock()

    public init() {}

    /// Returns the resolved overlay, loading it from the bundle on first access.
    public var overlay: OverlayDefinition {
        lock.withLock {
            if let cached = _cachedOverlay {
                return cached
            }
            let loaded = Self.loadOverlay()
            _cachedOverlay = loaded
            return loaded
        }
    }

    // MARK: - Apply overlay

    /// Enriches a raw FIT message with human-readable names from the overlay.
    ///
    /// - Parameters:
    ///   - messageNumber: The global message number of the FIT message.
    ///   - fields: Raw field number to value mapping from `FITMessage`.
    /// - Returns: An ``EnrichedFITMessage`` with resolved names.
    public func apply(toMessage messageNumber: UInt16, fields: [UInt8: FITFieldValue]) -> EnrichedFITMessage {
        let messageOverlay = overlay.messages[messageNumber]
        let enrichedFields: [EnrichedField] = fields.map { fieldNum, value in
            let fieldOverlay = messageOverlay?.fields[fieldNum]
            return EnrichedField(
                fieldNumber: fieldNum,
                name: fieldOverlay?.name,
                units: fieldOverlay?.units,
                value: value
            )
        }
        return EnrichedFITMessage(
            globalMessageNumber: messageNumber,
            messageName: messageOverlay?.name,
            fields: enrichedFields
        )
    }

    // MARK: - Private loading

    private static func loadOverlay() -> OverlayDefinition {
        guard let url = Bundle.module.url(forResource: "harry_overlay", withExtension: "json") else {
            logger.error("harry_overlay.json not found in bundle")
            return OverlayDefinition(messages: [:])
        }
        do {
            let data = try Data(contentsOf: url)
            let root = try JSONDecoder().decode(OverlayRoot.self, from: data)
            return resolve(root)
        } catch {
            logger.error("Failed to decode harry_overlay.json: \(error.localizedDescription)")
            return OverlayDefinition(messages: [:])
        }
    }

    /// Converts the JSON-friendly string-keyed ``OverlayRoot`` into the runtime ``OverlayDefinition``.
    private static func resolve(_ root: OverlayRoot) -> OverlayDefinition {
        var messages: [UInt16: MessageOverlay] = [:]
        for (messageKey, messageDef) in root.messages {
            guard let messageNum = UInt16(messageKey) else {
                logger.warning("Skipping non-numeric message key: \(messageKey)")
                continue
            }
            var fields: [UInt8: FieldOverlay] = [:]
            for (fieldKey, fieldDef) in messageDef.fields {
                guard let fieldNum = UInt8(fieldKey) else {
                    // Field numbers above 255 use the expanded field number scheme.
                    // For now we skip them.
                    logger.warning("Skipping non-UInt8 field key \(fieldKey) in message \(messageKey)")
                    continue
                }
                fields[fieldNum] = FieldOverlay(
                    name: fieldDef.name,
                    type: fieldDef.type,
                    units: fieldDef.units
                )
            }
            messages[messageNum] = MessageOverlay(name: messageDef.name, fields: fields)
        }
        return OverlayDefinition(messages: messages)
    }
}
