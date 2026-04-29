import Foundation

/// Garmin's custom CRC-16 (the same algorithm used in FIT files and GFDI).
///
/// Nibble-based: each input byte is split into two 4-bit nibbles and folded
/// through a 16-entry constant table. **Not** standard CRC-16-CCITT — using
/// the wrong algorithm produces a CRC that is silently rejected by the watch.
///
/// Reference: Gadgetbridge `ChecksumCalculator.java`, Garmin FIT SDK.
public enum CRC16 {

    private static let constants: [UInt16] = [
        0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
        0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400,
    ]

    /// Compute the Garmin CRC-16 over the given data.
    public static func compute(data: Data) -> UInt16 {
        var crc: UInt16 = 0x0000
        for byte in data {
            // Process low nibble of byte
            crc = ((crc >> 4) & 0x0FFF) ^ constants[Int(crc & 0x0F)] ^ constants[Int(byte & 0x0F)]
            // Process high nibble of byte
            crc = ((crc >> 4) & 0x0FFF) ^ constants[Int(crc & 0x0F)] ^ constants[Int((byte >> 4) & 0x0F)]
        }
        return crc
    }
}
