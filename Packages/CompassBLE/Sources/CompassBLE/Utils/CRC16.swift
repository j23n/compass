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

    /// Compute the Garmin CRC-16 over the given data, optionally starting from a seed.
    ///
    /// The `seed` parameter enables the running-CRC used for file transfer chunks:
    /// each chunk is verified against the cumulative CRC of all bytes received so far,
    /// not just the bytes in that chunk. Pass the previous call's return value as the
    /// seed for each subsequent chunk; use 0 for the first chunk or a full-file CRC.
    public static func compute(data: Data, seed: UInt16 = 0) -> UInt16 {
        var crc = seed
        for byte in data {
            crc = ((crc >> 4) & 0x0FFF) ^ constants[Int(crc & 0x0F)] ^ constants[Int(byte & 0x0F)]
            crc = ((crc >> 4) & 0x0FFF) ^ constants[Int(crc & 0x0F)] ^ constants[Int((byte >> 4) & 0x0F)]
        }
        return crc
    }
}
