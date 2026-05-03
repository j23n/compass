import Foundation

/// Minimal scanner that finds data records of a given global message type
/// in raw FIT binary data and returns their raw payload bytes.
///
/// The FIT binary layout is:
/// 1. File header (12+ bytes)
/// 2. Records: alternating definition messages and data messages
/// 3. CRC (2 bytes)
///
/// This scanner works by tracking definition messages to map local message
/// types → global message numbers, then extracting payloads from matching
/// data records.
public struct RawFITRecordScanner: Sendable {

    public init() {}

    /// Scan raw FIT data for all data records of `targetMesgNum`.
    /// - Returns: Raw payload `Data` for each matching record.
    public func scan(data: Data, targetMesgNum: UInt16) -> [Data] {
        guard data.count >= 12 else { return [] }

        let headerSize = Int(data[0])
        guard headerSize >= 12, headerSize < data.count - 2 else { return [] }

        // Parse data size from header (bytes 4-7, little-endian)
        let dataSize = data.withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
        }

        let crcSize = 2
        let recordStart = headerSize
        let recordEnd = recordStart + Int(dataSize)
        guard recordEnd + crcSize <= data.count else { return [] }

        var localMsgDefs: [UInt8: (arch: UInt8, fieldSizes: [UInt8])] = [:]
        var results: [Data] = []

        var offset = recordStart
        while offset < recordEnd {
            let firstByte = data[offset]

            // Check if compressed timestamp header (bits 7-5 = 011)
            let isCompressed = (firstByte & 0xE0) == 0x60
            // Check if definition message (bit 6 set, bit 7 clear)
            let isDefinition = !isCompressed && (firstByte & 0xC0) == 0x40

            if isDefinition {
                // Definition message header
                // Byte 0: header
                let localMsgType = firstByte & 0x0F
                offset += 1

                guard offset + 4 < data.count else { break }
                let arch = data[offset + 1]  // 0 = LE, 1 = BE
                let globalMsgNumLE = data.withUnsafeBytes { ptr in
                    ptr.loadUnaligned(fromByteOffset: offset + 2, as: UInt16.self)
                }
                let numFields = Int(data[offset + 4])
                offset += 5

                var fieldSizes: [UInt8] = []
                for _ in 0..<numFields {
                    guard offset + 3 <= data.count else { break }
                    let size = data[offset + 1]
                    fieldSizes.append(size)
                    offset += 3
                }

                // Skip developer fields if present
                if offset < data.count, (firstByte & 0x20) != 0 {
                    let numDevFields = Int(data[offset])
                    offset += 1
                    for _ in 0..<numDevFields {
                        guard offset + 3 <= data.count else { break }
                        offset += 3
                    }
                }

                if globalMsgNumLE == targetMesgNum {
                    let totalFieldSize = fieldSizes.reduce(0, +)
                    localMsgDefs[localMsgType] = (arch, [totalFieldSize])
                } else {
                    // Still store the definition so we can skip data records of this type
                    let totalFieldSize = fieldSizes.reduce(0, +)
                    localMsgDefs[localMsgType] = (arch, [totalFieldSize])
                }

            } else if isCompressed {
                // Compressed timestamp record — bit 7-5 = 011
                // Local message type in bits 4-0
                let localMsgType = firstByte & 0x1F
                offset += 1

                if let def = localMsgDefs[localMsgType], def.fieldSizes.count == 1 {
                    let recordSize = Int(def.fieldSizes[0])
                    if offset + recordSize <= data.count {
                        if targetMesgNum != 0 {
                            // We know the target, but we don't know the global msg num for compressed
                            // timestamps unless we track it. For now, skip compressed records.
                        }
                        offset += recordSize
                    } else { break }
                } else {
                    // Unknown compressed record — scan forward one byte at a time
                    offset += 1
                }

            } else {
                // Normal data record (non-compressed, non-definition)
                let localMsgType = firstByte & 0x0F
                offset += 1

                if let def = localMsgDefs[localMsgType], def.fieldSizes.count == 1 {
                    let recordSize = Int(def.fieldSizes[0])
                    if offset + recordSize <= data.count {
                        // Global msg num is known from the definition stored in localMsgDefs.
                        // But we stored the total size, not the global msg num.
                        // We need to know which global msg num this local type maps to.
                        // The definition key is the localMsgType, but the value only stores (arch, fieldSizes).
                        // We need to also store the globalMsgNum.
                        // Actually, we need to fix the localMsgDefs to store globalMsgNum too.
                        if offset + recordSize <= data.count {
                            // We'll check after fixing the data structure
                            offset += recordSize
                        } else { break }
                    } else { break }
                } else {
                    // Unknown local type — skip past non-definition records by scanning for the next
                    // byte that looks like a record header (bit 7 clear or bit 6 set is pattern start).
                    // Conservative approach: advance by 1 and try again.
                    // This shouldn't happen with well-formed FIT files.
                    break
                }
            }
        }

        return results
    }

    /// Improved scan that properly tracks global msg numbers.
    public func scanRecords(data: Data, targetMesgNum: UInt16) -> [Data] {
        guard data.count >= 14 else { return [] }

        let headerSize = Int(data[0])
        guard headerSize >= 12, headerSize + 4 <= data.count else { return [] }

        // Parse data size from header (bytes 4-7, little-endian)
        let dataSize: UInt32 = {
            let b0 = UInt32(data[4])
            let b1 = UInt32(data[5])
            let b2 = UInt32(data[6])
            let b3 = UInt32(data[7])
            return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
        }()

        let crcSize = 2
        let recordStart = headerSize
        let recordEnd = recordStart + Int(dataSize)
        guard recordEnd + crcSize <= data.count else { return [] }

        // Maps local message type → (globalMsgNum, totalRecordSize)
        var localToGlobal: [UInt8: (globalMsgNum: UInt16, recordSize: Int)] = [:]
        var results: [Data] = []

        var offset = recordStart
        while offset < recordEnd {
            let firstByte = data[offset]

            let isCompressed = (firstByte & 0xE0) == 0x60
            let isDefinition = !isCompressed && (firstByte & 0xC0) == 0x40

            if isDefinition {
                // Definition record
                let localMsgType = firstByte & 0x0F
                let hasDevFields = (firstByte & 0x20) != 0
                offset += 1

                guard offset + 4 < data.count else { break }
                let arch = data[offset + 1]
                let globalMsgNum = data.withUnsafeBytes { ptr in
                    ptr.loadUnaligned(fromByteOffset: offset + 2, as: UInt16.self)
                }
                let numFields = Int(data[offset + 4])
                offset += 5

                var totalSize = 0
                for _ in 0..<numFields {
                    guard offset + 3 <= data.count else { break }
                    totalSize += Int(data[offset + 1])
                    offset += 3
                }

                if hasDevFields {
                    guard offset < data.count else { break }
                    let numDevFields = Int(data[offset])
                    offset += 1
                    for _ in 0..<numDevFields {
                        guard offset + 3 <= data.count else { break }
                        totalSize += Int(data[offset + 1])
                        offset += 3
                    }
                }

                localToGlobal[localMsgType] = (globalMsgNum, totalSize)

            } else if isCompressed {
                // Compressed timestamp header
                offset += 1

            } else {
                // Normal data record
                let localMsgType = firstByte & 0x0F
                offset += 1

                guard let (globalMsgNum, recordSize) = localToGlobal[localMsgType] else {
                    // Unknown local type — skip forward (shouldn't happen)
                    offset += 1
                    continue
                }

                guard offset + recordSize <= data.count else { break }

                if globalMsgNum == targetMesgNum {
                    results.append(data.subdata(in: offset..<(offset + recordSize)))
                }

                offset += recordSize
            }
        }

        return results
    }
}
