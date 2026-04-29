import Testing
import Foundation
@testable import CompassFIT

@Suite("FieldNameOverlay")
struct OverlayTests {

    @Test("Overlay JSON loads without errors")
    func overlayLoads() {
        let overlay = FieldNameOverlay()
        let definition = overlay.overlay
        // The JSON defines 8 message types.
        #expect(definition.messages.count == 8)
    }

    @Test("Known message numbers resolve to correct names")
    func messageNameResolution() {
        let overlay = FieldNameOverlay()
        let definition = overlay.overlay

        #expect(definition.messages[140]?.name == "monitoring_hr")
        #expect(definition.messages[211]?.name == "monitoring_info")
        #expect(definition.messages[273]?.name == "sleep_data_info")
        #expect(definition.messages[275]?.name == "sleep_stage")
        #expect(definition.messages[346]?.name == "body_battery")
        #expect(definition.messages[369]?.name == "training_readiness")
        #expect(definition.messages[382]?.name == "sleep_restless_moments")
        #expect(definition.messages[412]?.name == "nap")
    }

    @Test("Field names resolve within a message")
    func fieldNameResolution() {
        let overlay = FieldNameOverlay()
        let definition = overlay.overlay

        // body_battery (346): field 0 = level, field 1 = charged, field 2 = drained
        let bb = definition.messages[346]
        #expect(bb != nil)
        #expect(bb?.fields[0]?.name == "level")
        #expect(bb?.fields[1]?.name == "charged")
        #expect(bb?.fields[2]?.name == "drained")

        // sleep_stage (275): field 0 = stage, field 1 = duration
        let stage = definition.messages[275]
        #expect(stage?.fields[0]?.name == "stage")
        #expect(stage?.fields[1]?.name == "duration")
    }

    @Test("Timestamp field (253) is present in all messages")
    func timestampFieldPresent() {
        let overlay = FieldNameOverlay()
        let definition = overlay.overlay

        for (messageNum, messageOverlay) in definition.messages {
            #expect(
                messageOverlay.fields[253]?.name == "timestamp",
                "Message \(messageNum) (\(messageOverlay.name)) should have timestamp at field 253"
            )
        }
    }

    @Test("Unknown message numbers return nil in overlay")
    func unknownMessageNumber() {
        let overlay = FieldNameOverlay()
        let definition = overlay.overlay
        #expect(definition.messages[9999] == nil)
    }

    @Test("apply(toMessage:fields:) enriches known fields")
    func applyEnrichesKnownFields() {
        let overlay = FieldNameOverlay()

        let fields: [UInt8: FITFieldValue] = [
            253: .uint32(1_000_000),
            0: .uint8(75),
            1: .int8(5),
            2: .int8(3),
        ]

        let enriched = overlay.apply(toMessage: 346, fields: fields)
        #expect(enriched.messageName == "body_battery")
        #expect(enriched.globalMessageNumber == 346)

        let fieldsByName = Dictionary(
            enriched.fields.map { ($0.name ?? "field_\($0.fieldNumber)", $0) },
            uniquingKeysWith: { first, _ in first }
        )
        #expect(fieldsByName["timestamp"] != nil)
        #expect(fieldsByName["level"]?.value == .uint8(75))
        #expect(fieldsByName["charged"]?.value == .int8(5))
        #expect(fieldsByName["drained"]?.value == .int8(3))
    }

    @Test("apply(toMessage:fields:) handles unknown message gracefully")
    func applyHandlesUnknownMessage() {
        let overlay = FieldNameOverlay()

        let fields: [UInt8: FITFieldValue] = [
            0: .uint8(42),
        ]

        let enriched = overlay.apply(toMessage: 9999, fields: fields)
        #expect(enriched.messageName == nil)
        #expect(enriched.fields.count == 1)
        #expect(enriched.fields[0].name == nil)
    }

    @Test("Field units are resolved correctly")
    func fieldUnitsResolution() {
        let overlay = FieldNameOverlay()
        let definition = overlay.overlay

        // monitoring_hr (140): heart_rate should have units "bpm"
        let hrField = definition.messages[140]?.fields[1]
        #expect(hrField?.units == "bpm")

        // monitoring_info (211): active_calories should have units "kcal"
        let calField = definition.messages[211]?.fields[3]
        #expect(calField?.units == "kcal")
    }

    @Test("OverlayRoot is Codable round-trip safe")
    func overlayRoundTrip() throws {
        let root = OverlayRoot(
            version: "1.0",
            source: "test",
            messages: [
                "42": MessageDefinition(
                    name: "test_message",
                    fields: [
                        "0": FieldDefinition(name: "test_field", type: "uint8", units: "bpm")
                    ]
                )
            ]
        )

        let encoded = try JSONEncoder().encode(root)
        let decoded = try JSONDecoder().decode(OverlayRoot.self, from: encoded)

        #expect(decoded.version == "1.0")
        #expect(decoded.messages["42"]?.name == "test_message")
        #expect(decoded.messages["42"]?.fields["0"]?.name == "test_field")
    }
}
