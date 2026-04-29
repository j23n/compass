import Foundation

// MARK: - JSON-Codable overlay structures

/// Root of the harry_overlay.json file.
public struct OverlayRoot: Codable, Sendable {
    public let version: String
    public let source: String
    /// Keyed by global message number (as a string in JSON).
    public let messages: [String: MessageDefinition]

    public init(version: String, source: String, messages: [String: MessageDefinition]) {
        self.version = version
        self.source = source
        self.messages = messages
    }
}

/// Definition for a single FIT message type in the overlay.
public struct MessageDefinition: Codable, Sendable {
    public let name: String
    /// Keyed by field definition number (as a string in JSON).
    public let fields: [String: FieldDefinition]

    public init(name: String, fields: [String: FieldDefinition]) {
        self.name = name
        self.fields = fields
    }
}

/// Definition for a single field within a message.
public struct FieldDefinition: Codable, Sendable {
    public let name: String
    public let type: String
    public let units: String

    public init(name: String, type: String, units: String) {
        self.name = name
        self.type = type
        self.units = units
    }
}
