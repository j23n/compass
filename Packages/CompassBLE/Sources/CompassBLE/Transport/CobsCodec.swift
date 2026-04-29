import Foundation

/// Garmin-variant COBS (Consistent Overhead Byte Stuffing).
///
/// Differs from standard COBS by adding a **leading** 0x00 in addition to the
/// trailing 0x00. So every encoded message is:
///
/// ```
/// 0x00 [code, data...] [code, data...] ... 0x00
/// ```
///
/// Each `code` is 1..255 indicating "skip count + 1" — `count` data bytes
/// follow with no zeros, and a synthetic 0x00 is implicit between blocks
/// unless the code was 0xFF (no implicit zero) or this is the last block.
///
/// Reference: Gadgetbridge `CobsCoDec.java`
public struct CobsCodec {

    /// Encode raw bytes into a COBS frame with leading + trailing 0x00.
    public static func encode(_ data: Data) -> Data {
        var out = Data(capacity: data.count * 2 + 2)
        out.append(0x00) // Garmin's leading padding

        let bytes = [UInt8](data)
        var pos = 0
        var lastByteWasZero = false

        while pos < bytes.count {
            let start = pos
            // Walk forward until we hit a zero or end.
            while pos < bytes.count && bytes[pos] != 0 {
                pos += 1
            }
            lastByteWasZero = (pos < bytes.count) // landed on a zero
            var payloadSize = pos - start
            var blockStart = start

            // Long runs (>=0xFE non-zero bytes): emit 0xFF blocks.
            while payloadSize >= 0xFE {
                out.append(0xFF)
                out.append(contentsOf: bytes[blockStart..<(blockStart + 0xFE)])
                payloadSize -= 0xFE
                blockStart += 0xFE
            }

            out.append(UInt8(payloadSize + 1))
            if payloadSize > 0 {
                out.append(contentsOf: bytes[blockStart..<(blockStart + payloadSize)])
            }

            if pos < bytes.count {
                pos += 1 // skip the zero we landed on
            }
        }

        if lastByteWasZero {
            out.append(0x01) // trailing empty block to encode the final zero
        }

        out.append(0x00) // trailing terminator
        return out
    }

    /// Stateful decoder: feed bytes as they arrive, retrieve a complete
    /// decoded message when the trailing 0x00 has been seen.
    public final class Decoder {
        private var buffer = Data()
        private var pending: Data?

        /// Reset both the input buffer and any pending decoded message.
        public func reset() {
            buffer.removeAll(keepingCapacity: true)
            pending = nil
        }

        /// Append received bytes and try to decode a full message.
        public func receivedBytes(_ data: Data) {
            buffer.append(data)
            decodeIfReady()
        }

        /// Returns and clears any complete decoded message.
        public func retrieveMessage() -> Data? {
            let msg = pending
            pending = nil
            // After consuming the message, attempt to decode the next.
            if msg != nil { decodeIfReady() }
            return msg
        }

        public init() {}

        private func decodeIfReady() {
            guard pending == nil else { return }
            guard buffer.count >= 4 else { return }
            // Need a trailing zero byte.
            guard let lastZero = buffer.lastIndex(of: 0) else { return }
            // Find the leading zero before that.
            // The encoded frame is bounded by the leading 0 and the trailing 0.
            // We expect buffer[0] == 0 (leading) and buffer[lastZero] == 0 (trailing).
            // If we don't have a leading zero, drop everything up to the first zero.
            if let firstZero = buffer.firstIndex(of: 0), firstZero > 0 {
                buffer.removeSubrange(0..<firstZero)
                return decodeIfReady()
            }
            guard buffer.first == 0, lastZero > 0 else { return }

            // Slice the body between leading and trailing zeros.
            let bodyStart = 1
            let bodyEnd = lastZero
            guard bodyEnd > bodyStart else { return }
            let body = buffer[bodyStart..<bodyEnd]

            var out = Data()
            var i = body.startIndex
            while i < body.endIndex {
                let code = Int(body[i])
                i += 1
                let payloadSize = code - 1
                guard payloadSize >= 0, i + payloadSize <= body.endIndex else {
                    // Malformed — drop the frame.
                    buffer.removeSubrange(0...lastZero)
                    return
                }
                out.append(contentsOf: body[i..<(i + payloadSize)])
                i += payloadSize
                // Synthetic zero between blocks unless code == 0xFF or this is the last block.
                if code != 0xFF && i < body.endIndex {
                    out.append(0x00)
                }
            }

            pending = out
            buffer.removeSubrange(0...lastZero)
        }
    }
}
