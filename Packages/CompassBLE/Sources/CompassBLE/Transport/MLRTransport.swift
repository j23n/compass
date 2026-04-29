import Foundation
import os

/// Actor implementing Multi-Link Reliable (MLR) transport framing.
///
/// MLR is the framing layer between raw BLE characteristic writes and the GFDI
/// application protocol. It provides:
/// - Multiplexing: multiple logical channels over one characteristic pair (via handles)
/// - Reliability: sequence numbers and ACK management
/// - Fragmentation: large GFDI messages split across multiple BLE writes
///
/// ## Wire Format
///
/// Each MLR frame has a 2-byte header followed by the payload:
///
/// ```
/// Byte 0: 0x80 | (handle << 4) | (req_num >> 2)
///         - Bit 7: always 1 (MLR marker)
///         - Bits 6-4: handle (0-7, identifies the logical channel)
///         - Bits 3-0: upper 4 bits of req_num (ACK sequence)
///
/// Byte 1: (req_num << 6) | seq_num
///         - Bits 7-6: lower 2 bits of req_num
///         - Bits 5-0: seq_num (0-63, this frame's sequence number)
///
/// Bytes 2+: payload (GFDI message fragment)
/// ```
///
/// The `req_num` field acknowledges received frames from the peer (it's the
/// sequence number of the last correctly received frame + 1). The `seq_num`
/// is incremented for each frame sent on a given handle.
///
/// Handle 0 is the control channel used for MLR protocol management (handle
/// open/close). Handles 1+ carry application data (typically GFDI).
///
/// Reference: Gadgetbridge `GarminSupport.java` — MLR encode/decode logic.
///            Gadgetbridge `GFDIStatusMessage.java` — MLR status handling.
public actor MLRTransport {

    // MARK: - Per-Handle State

    /// Sequence number state for a single MLR handle.
    private struct HandleState {
        /// The next sequence number to use when sending on this handle.
        var sendSeqNum: UInt8 = 0

        /// The next expected sequence number from the peer (used in ACKs).
        var recvSeqNum: UInt8 = 0

        /// The last req_num we sent (ACKing peer's frames).
        var lastAckSent: UInt8 = 0
    }

    /// Per-handle sequence state.
    private var handleStates: [UInt8: HandleState] = [:]

    /// The handle manager for assigning logical channels.
    public let handleManager: HandleManager

    // MARK: - Init

    /// Creates a new MLR transport with a fresh handle manager.
    public init() {
        self.handleManager = HandleManager()
    }

    // MARK: - Encode

    /// Encode a payload into an MLR frame for the given handle.
    ///
    /// Constructs the 2-byte MLR header from the current sequence numbers and
    /// prepends it to the payload.
    ///
    /// - Parameters:
    ///   - payload: The GFDI message bytes to wrap.
    ///   - handle: The MLR handle (0-7) for this channel.
    /// - Returns: The complete MLR frame (header + payload).
    public func encode(payload: Data, handle: UInt8) -> Data {
        var state = handleStates[handle] ?? HandleState()

        let seqNum = state.sendSeqNum
        let reqNum = state.lastAckSent

        // Build the 2-byte header
        // Byte 0: 0x80 | (handle << 4) | (reqNum >> 2)
        let byte0 = UInt8(0x80) | ((handle & 0x07) << 4) | ((reqNum >> 2) & 0x0F)

        // Byte 1: (reqNum << 6) | seqNum
        let byte1 = ((reqNum & 0x03) << 6) | (seqNum & 0x3F)

        // Increment send sequence number (wraps at 64)
        state.sendSeqNum = (seqNum + 1) & 0x3F
        handleStates[handle] = state

        var frame = Data(capacity: 2 + payload.count)
        frame.append(byte0)
        frame.append(byte1)
        frame.append(payload)

        BLELogger.transport.debug(
            "MLR encode: handle=\(handle) seq=\(seqNum) req=\(reqNum) payloadLen=\(payload.count)"
        )

        return frame
    }

    // MARK: - Decode

    /// Decoded result from an MLR frame.
    public struct DecodedFrame: Sendable {
        /// The handle this frame belongs to (0-7).
        public let handle: UInt8

        /// The sender's sequence number.
        public let seqNum: UInt8

        /// The sender's ACK (acknowledges our frames up to this number).
        public let reqNum: UInt8

        /// The GFDI payload bytes (after stripping the MLR header).
        public let payload: Data
    }

    /// Decode an MLR frame from raw BLE notification data.
    ///
    /// - Parameter data: The raw bytes received from a BLE notification.
    /// - Returns: The decoded handle, sequence numbers, and payload.
    /// - Throws: If the data is too short to contain a valid MLR header.
    public func decode(data: Data) throws -> DecodedFrame {
        guard data.count >= 2 else {
            throw MLRError.frameTooShort(length: data.count)
        }

        let byte0 = data[data.startIndex]
        let byte1 = data[data.startIndex + 1]

        // Verify MLR marker bit
        guard byte0 & 0x80 != 0 else {
            throw MLRError.invalidMarker(byte: byte0)
        }

        let handle = (byte0 >> 4) & 0x07
        let reqNumHigh = UInt8(byte0 & 0x0F) << 2
        let reqNumLow = (byte1 >> 6) & 0x03
        let reqNum = reqNumHigh | reqNumLow
        let seqNum = byte1 & 0x3F

        let payload = data.count > 2 ? Data(data[(data.startIndex + 2)...]) : Data()

        // Update our ACK state: we received this seq from the peer
        var state = handleStates[handle] ?? HandleState()
        state.recvSeqNum = (seqNum + 1) & 0x3F
        state.lastAckSent = state.recvSeqNum
        handleStates[handle] = state

        BLELogger.transport.debug(
            "MLR decode: handle=\(handle) seq=\(seqNum) req=\(reqNum) payloadLen=\(payload.count)"
        )

        return DecodedFrame(handle: handle, seqNum: seqNum, reqNum: reqNum, payload: payload)
    }

    // MARK: - ACK Management

    /// Generate an ACK frame for the given handle.
    ///
    /// An ACK frame has no payload — it just carries the updated req_num to tell
    /// the peer we've received their frames.
    ///
    /// - Parameter handle: The handle to ACK on.
    /// - Returns: A 2-byte ACK frame.
    public func generateAck(forHandle handle: UInt8) -> Data {
        return encode(payload: Data(), handle: handle)
    }

    /// Reset all per-handle sequence state. Called on disconnect.
    public func reset() async {
        handleStates.removeAll()
        await handleManager.reset()
        BLELogger.transport.info("MLR transport reset")
    }

    // MARK: - Errors

    /// Errors specific to MLR frame processing.
    public enum MLRError: Error, Sendable {
        /// The received data was too short to contain a valid MLR header.
        case frameTooShort(length: Int)

        /// The first byte did not have the MLR marker bit set.
        case invalidMarker(byte: UInt8)
    }
}
