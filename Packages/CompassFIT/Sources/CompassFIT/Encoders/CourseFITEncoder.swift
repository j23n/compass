import Foundation

/// Simple waypoint structure for FIT encoding
public struct FITCourseWaypoint: Sendable {
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double?
    public let name: String?
    public let distanceFromStart: Double

    public init(latitude: Double, longitude: Double, altitude: Double?, name: String?, distanceFromStart: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.name = name
        self.distanceFromStart = distanceFromStart
    }
}

/// Encodes a course into a binary FIT file suitable for upload to a Garmin device.
public struct CourseFITEncoder: Sendable {

    /// Encodes a course into FIT binary format.
    public static func encode(name: String, waypoints: [FITCourseWaypoint], totalDistance: Double) -> Data {
        var body = Data()

        // 1. File ID message
        encodeFileIDMessage(into: &body)

        // 2. Course message
        encodeCourseMessage(name: name, into: &body)

        // 3. Lap message
        encodeLapMessage(waypoints: waypoints, totalDistance: totalDistance, into: &body)

        // 4. Record messages (one per waypoint)
        for waypoint in waypoints {
            encodeRecordMessage(waypoint: waypoint, into: &body)
        }

        // 5. Course point messages (for named waypoints)
        let namedWaypoints = waypoints.filter { $0.name != nil }
        for waypoint in namedWaypoints {
            encodeCoursePointMessage(waypoint: waypoint, into: &body)
        }

        // Build file with header and CRC
        let file = buildFITFile(body: body)
        return file
    }

    // MARK: - FIT File Structure

    private static func buildFITFile(body: Data) -> Data {
        var file = Data()

        // Header (14 bytes)
        let headerSize: UInt8 = 14
        let protocolVersion: UInt8 = 16
        let profileVersion: UInt16 = 2134
        file.append(headerSize)
        file.append(protocolVersion)
        file.appendUInt16LE(profileVersion)
        file.appendUInt32LE(UInt32(body.count))
        file.append(contentsOf: Data(".FIT".utf8))  // 4 bytes: 0x2E 0x46 0x49 0x54

        // Body
        file.append(body)

        // Trailing CRC (computed over body only)
        let crc = computeFITCRC(body)
        file.appendUInt16LE(crc)

        return file
    }

    // MARK: - Message Encoders

    private static func encodeFileIDMessage(into body: inout Data) {
        // Definition message (local type 0, global type 0)
        var defMsg = Data()
        defMsg.append(0)  // reserved
        defMsg.append(0)  // architecture (little-endian)
        defMsg.appendUInt16LE(0)  // global message type (file_id)
        defMsg.append(5)  // numFields

        // Field 0: type (field num 0, size 1, type 0 = UInt8)
        defMsg.append(0); defMsg.append(1); defMsg.append(0)
        // Field 1: manufacturer (field num 1, size 2, type 0x84 = UInt16LE)
        defMsg.append(1); defMsg.append(2); defMsg.append(0x84)
        // Field 2: product (field num 2, size 2, type 0x84 = UInt16LE)
        defMsg.append(2); defMsg.append(2); defMsg.append(0x84)
        // Field 3: time_created (field num 3, size 4, type 0x86 = UInt32LE)
        defMsg.append(3); defMsg.append(4); defMsg.append(0x86)
        // Field 4: serial_number (field num 4, size 4, type 0x86 = UInt32LE)
        defMsg.append(4); defMsg.append(4); defMsg.append(0x86)

        encodeDefinitionMessageHeader(&defMsg, localType: 0)
        body.append(defMsg)

        // Data message (local type 0)
        var dataMsg = Data()
        dataMsg.append(6)  // type = COURSE
        dataMsg.appendUInt16LE(255)  // manufacturer = invalid
        dataMsg.appendUInt16LE(1)    // product = generic
        let timestamp = UInt32(Date().timeIntervalSince(FITTimestamp.epoch))
        dataMsg.appendUInt32LE(timestamp)  // time_created
        dataMsg.appendUInt32LE(0)    // serial_number

        encodeDataMessageHeader(&dataMsg, localType: 0)
        body.append(dataMsg)
    }

    private static func encodeCourseMessage(name: String, into body: inout Data) {
        // Definition message (local type 1, global type 31 = course)
        var defMsg = Data()
        defMsg.append(0)  // reserved
        defMsg.append(0)  // architecture
        defMsg.appendUInt16LE(31)  // global message type (course)
        defMsg.append(1)  // numFields

        // Field 0: name (field num 0, size 16, type 7 = String)
        defMsg.append(0); defMsg.append(16); defMsg.append(7)

        encodeDefinitionMessageHeader(&defMsg, localType: 1)
        body.append(defMsg)

        // Data message (local type 1)
        var dataMsg = Data()
        let nameBytes = padString(name, to: 16)
        dataMsg.append(contentsOf: nameBytes)

        encodeDataMessageHeader(&dataMsg, localType: 1)
        body.append(dataMsg)
    }

    private static func encodeLapMessage(waypoints: [FITCourseWaypoint], totalDistance: Double, into body: inout Data) {
        // Definition message (local type 2, global type 19 = lap)
        var defMsg = Data()
        defMsg.append(0)  // reserved
        defMsg.append(0)  // architecture
        defMsg.appendUInt16LE(19)  // global message type (lap)
        defMsg.append(8)  // numFields

        let fields: [(UInt8, UInt8, UInt8)] = [
            (0, 1, 0),     // event (UInt8)
            (1, 1, 0),     // event_type (UInt8)
            (2, 4, 0x86),  // start_time (UInt32LE)
            (254, 4, 0x86), // timestamp (UInt32LE)
            (3, 4, 0x85),  // start_position_lat (Int32LE semicircles)
            (4, 4, 0x85),  // start_position_long (Int32LE semicircles)
            (7, 4, 0x86),  // total_distance (UInt32LE centimeters)
            (10, 4, 0x86), // total_elapsed_time (UInt32LE milliseconds)
        ]

        for (fieldNum, size, baseType) in fields {
            defMsg.append(fieldNum)
            defMsg.append(size)
            defMsg.append(baseType)
        }

        encodeDefinitionMessageHeader(&defMsg, localType: 2)
        body.append(defMsg)

        // Data message (local type 2)
        var dataMsg = Data()
        let timestamp = UInt32(Date().timeIntervalSince(FITTimestamp.epoch))
        let firstWaypoint = waypoints.first

        dataMsg.append(0)  // event = TIMER
        dataMsg.append(0)  // event_type = START
        dataMsg.appendUInt32LE(timestamp)  // start_time
        dataMsg.appendUInt32LE(timestamp)  // timestamp
        dataMsg.appendInt32LE(degreesToSemicircles(firstWaypoint?.latitude ?? 0))  // start_position_lat
        dataMsg.appendInt32LE(degreesToSemicircles(firstWaypoint?.longitude ?? 0))  // start_position_long
        dataMsg.appendUInt32LE(UInt32(totalDistance * 100))  // total_distance (cm)
        dataMsg.appendUInt32LE(0)  // total_elapsed_time (ms) = 0 for static course

        encodeDataMessageHeader(&dataMsg, localType: 2)
        body.append(dataMsg)
    }

    private static func encodeRecordMessage(waypoint: FITCourseWaypoint, into body: inout Data) {
        // Definition message only for first waypoint
        if waypoint.distanceFromStart == 0 {
            var defMsg = Data()
            defMsg.append(0)  // reserved
            defMsg.append(0)  // architecture
            defMsg.appendUInt16LE(20)  // global message type (record)
            defMsg.append(6)  // numFields

            let fields: [(UInt8, UInt8, UInt8)] = [
                (254, 4, 0x86),  // timestamp (UInt32LE)
                (0, 4, 0x85),    // position_lat (Int32LE)
                (1, 4, 0x85),    // position_long (Int32LE)
                (2, 2, 0x84),    // altitude (UInt16LE)
                (3, 4, 0x86),    // distance (UInt32LE)
                (5, 1, 0),       // cadence (UInt8)
            ]

            for (fieldNum, size, baseType) in fields {
                defMsg.append(fieldNum)
                defMsg.append(size)
                defMsg.append(baseType)
            }

            encodeDefinitionMessageHeader(&defMsg, localType: 3)
            body.append(defMsg)
        }

        // Data message (local type 3)
        var dataMsg = Data()
        let timestamp = UInt32(Date().timeIntervalSince(FITTimestamp.epoch))
        dataMsg.appendUInt32LE(timestamp)  // timestamp
        dataMsg.appendInt32LE(degreesToSemicircles(waypoint.latitude))  // position_lat
        dataMsg.appendInt32LE(degreesToSemicircles(waypoint.longitude))  // position_long
        dataMsg.appendUInt16LE(encodeAltitude(waypoint.altitude ?? 0))  // altitude
        dataMsg.appendUInt32LE(UInt32(waypoint.distanceFromStart * 100))  // distance (cm)
        dataMsg.append(0)  // cadence

        encodeDataMessageHeader(&dataMsg, localType: 3)
        body.append(dataMsg)
    }

    private static func encodeCoursePointMessage(waypoint: FITCourseWaypoint, into body: inout Data) {
        // Definition message only once
        var defMsg = Data()
        defMsg.append(0)  // reserved
        defMsg.append(0)  // architecture
        defMsg.appendUInt16LE(32)  // global message type (course_point)
        defMsg.append(6)  // numFields

        let fields: [(UInt8, UInt8, UInt8)] = [
            (254, 4, 0x86),  // timestamp (UInt32LE)
            (0, 4, 0x85),    // position_lat (Int32LE)
            (1, 4, 0x85),    // position_long (Int32LE)
            (2, 4, 0x86),    // distance (UInt32LE)
            (4, 1, 0),       // type (UInt8)
            (3, 16, 7),      // name (String)
        ]

        for (fieldNum, size, baseType) in fields {
            defMsg.append(fieldNum)
            defMsg.append(size)
            defMsg.append(baseType)
        }

        encodeDefinitionMessageHeader(&defMsg, localType: 4)
        body.append(defMsg)

        // Data message (local type 4)
        var dataMsg = Data()
        let timestamp = UInt32(Date().timeIntervalSince(FITTimestamp.epoch))
        dataMsg.appendUInt32LE(timestamp)  // timestamp
        dataMsg.appendInt32LE(degreesToSemicircles(waypoint.latitude))  // position_lat
        dataMsg.appendInt32LE(degreesToSemicircles(waypoint.longitude))  // position_long
        dataMsg.appendUInt32LE(UInt32(waypoint.distanceFromStart * 100))  // distance (cm)
        dataMsg.append(0)  // type = GENERIC
        let name = padString(waypoint.name ?? "", to: 16)
        dataMsg.append(contentsOf: name)  // name

        encodeDataMessageHeader(&dataMsg, localType: 4)
        body.append(dataMsg)
    }

    // MARK: - Helpers

    private static func encodeDefinitionMessageHeader(_ message: inout Data, localType: UInt8) {
        var header: UInt8 = 0x40  // Definition message header
        header |= localType & 0x0F
        message.insert(header, at: 0)
    }

    private static func encodeDataMessageHeader(_ message: inout Data, localType: UInt8) {
        var header: UInt8 = 0x00  // Data message header
        header |= localType & 0x0F
        message.insert(header, at: 0)
    }

    private static func degreesToSemicircles(_ degrees: Double) -> Int32 {
        return Int32(degrees * (pow(2.0, 31) / 180.0))
    }

    private static func encodeAltitude(_ meters: Double) -> UInt16 {
        let scaled = (meters + 500.0) * 5.0
        return UInt16(max(0, min(65535, scaled)))
    }

    private static func padString(_ str: String, to length: Int) -> Data {
        var bytes = Array(str.utf8)
        if bytes.count > length {
            bytes = Array(bytes.prefix(length))
        } else {
            bytes.append(contentsOf: Array(repeating: UInt8(0), count: length - bytes.count))
        }
        return Data(bytes)
    }
}

// MARK: - FIT Utilities

private func computeFITCRC(_ data: Data) -> UInt16 {
    let table: [UInt16] = [
        0x0000, 0xCC01, 0xD801, 0x1400,
        0xF001, 0x3C00, 0x2800, 0xE401,
        0xA001, 0x6C00, 0x7800, 0xB401,
        0x5000, 0x9C01, 0x8801, 0x4400
    ]

    var crc: UInt16 = 0
    for byte in data {
        var tmp = table[Int(crc & 0xF)]
        crc = (crc >> 4) & 0x0FFF
        crc = crc ^ tmp ^ table[Int(byte & 0xF)]
        tmp = table[Int(crc & 0xF)]
        crc = (crc >> 4) & 0x0FFF
        crc = crc ^ tmp ^ table[Int((byte >> 4) & 0xF)]
    }
    return crc
}

// MARK: - Data Helpers

extension Data {
    fileprivate mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    fileprivate mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }

    fileprivate mutating func appendInt32LE(_ value: Int32) {
        appendUInt32LE(UInt32(bitPattern: value))
    }
}
