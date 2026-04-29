import Foundation
import os

/// Reassembles fragmented BLE notifications into complete GFDI messages.
///
/// BLE has a maximum transmission unit (MTU) that limits the size of a single
/// notification (typically 20-512 bytes depending on negotiation). GFDI messages
/// can be much larger, so they are fragmented across multiple MLR frames.
///
/// The GFDI wire format starts with a 2-byte little-endian length prefix that
/// indicates the total message size (including the length field itself). The
/// assembler uses this to know when all fragments have been received.
///
/// ## Reassembly Algorithm
///
/// 1. First fragment: read the 2-byte LE length prefix → this is `expectedLength`
/// 2. Append all fragment payloads to a buffer
/// 3. When `buffer.count >= expectedLength`, decode the complete GFDI message
/// 4. Any excess bytes are retained for the next message (pipelining)
///
/// Each MLR handle has independent reassembly state, so frames from different
/// handles don't interfere with each other.
///
/// Reference: Gadgetbridge `GFDIStatusMessage.java` — fragment reassembly.
public actor FrameAssembler {

    /// Per-handle assembly buffer.
    private struct AssemblyBuffer {
        /// Accumulated bytes for the current message.
        var data: Data = Data()

        /// The expected total length from the GFDI length prefix, or nil if
        /// we haven't received enough bytes to read the length yet.
        var expectedLength: Int?

        /// Reset the buffer for the next message.
        mutating func reset() {
            data = Data()
            expectedLength = nil
        }
    }

    /// Assembly buffers keyed by MLR handle.
    private var buffers: [UInt8: AssemblyBuffer] = [:]

    public init() {}

    /// Feed a fragment into the assembler.
    ///
    /// - Parameters:
    ///   - data: The payload bytes from an MLR frame (MLR header already stripped).
    ///   - handle: The MLR handle this fragment belongs to.
    /// - Returns: A complete ``GFDIMessage`` if the fragment completed a message,
    ///           or `nil` if more fragments are needed.
    /// - Throws: If the assembled data fails GFDI message decoding.
    public func feed(data: Data, handle: UInt8) throws -> GFDIMessage? {
        guard !data.isEmpty else {
            return nil
        }

        var buffer = buffers[handle] ?? AssemblyBuffer()
        buffer.data.append(data)

        // Try to read the expected length from the first 2 bytes
        if buffer.expectedLength == nil && buffer.data.count >= 2 {
            let lo = Int(buffer.data[buffer.data.startIndex])
            let hi = Int(buffer.data[buffer.data.startIndex + 1])
            buffer.expectedLength = lo | (hi << 8)
            BLELogger.transport.debug(
                "Frame assembler: handle=\(handle) expectedLength=\(buffer.expectedLength ?? 0)"
            )
        }

        // Check if we have a complete message
        if let expectedLength = buffer.expectedLength, buffer.data.count >= expectedLength {
            let messageData = Data(buffer.data.prefix(expectedLength))

            // Retain any excess bytes for the next message
            if buffer.data.count > expectedLength {
                let excess = Data(buffer.data.suffix(from: buffer.data.startIndex + expectedLength))
                buffer.data = excess
                buffer.expectedLength = nil
            } else {
                buffer.reset()
            }

            buffers[handle] = buffer

            BLELogger.transport.debug(
                "Frame assembler: complete message on handle \(handle), \(messageData.count) bytes"
            )

            return try GFDIMessage.decode(from: messageData)
        }

        buffers[handle] = buffer

        BLELogger.transport.debug(
            "Frame assembler: handle=\(handle) buffered=\(buffer.data.count)/\(buffer.expectedLength ?? 0)"
        )

        return nil
    }

    /// Reset the assembly buffer for a specific handle.
    ///
    /// Called when a handle is closed or on error recovery.
    public func reset(handle: UInt8) {
        buffers[handle] = nil
    }

    /// Reset all assembly buffers. Called on disconnect.
    public func resetAll() {
        buffers.removeAll()
    }
}
