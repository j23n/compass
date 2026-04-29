import Foundation

/// Simple waypoint structure for FIT encoding.
///
/// `name` only applies to course points (POIs). Track points along the route
/// have name = nil and are emitted as `record` messages; named waypoints are
/// additionally emitted as `course_point` messages so they show as POI markers
/// on the watch.
public struct FITCourseWaypoint: Sendable {
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double?
    public let name: String?
    public let distanceFromStart: Double
    /// FIT `course_point` type enum (0=generic, 1=summit, 2=valley, 3=water, 4=food, 5=danger, 6=left, 7=right, 8=straight, 9=first_aid, …). Only used when `name != nil`.
    public let coursePointType: UInt8

    public init(
        latitude: Double,
        longitude: Double,
        altitude: Double?,
        name: String?,
        distanceFromStart: Double,
        coursePointType: UInt8 = 0
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.name = name
        self.distanceFromStart = distanceFromStart
        self.coursePointType = coursePointType
    }
}

/// Encodes a course into a binary FIT file suitable for upload to a Garmin device.
///
/// All field numbers follow the FIT SDK profile (Profile.xlsx). The watch
/// parses messages by field number, not order, so wrong field numbers cause
/// silent metadata loss (no name → fallback filename, no distance, etc.).
public struct CourseFITEncoder: Sendable {

    /// Encodes a course into FIT binary format.
    ///
    /// - Parameters:
    ///   - name: Course name. Truncated to 15 ASCII chars + null in the FIT `course.name` field.
    ///   - sport: FIT `sport` enum value (see FIT SDK). 0=generic, 1=running, 2=cycling, 11=walking, 17=hiking, …
    ///   - waypoints: Track points along the route. These become FIT `record` messages.
    ///   - pointsOfInterest: Named POI markers (separate from track points). Each becomes a FIT `course_point`. The watch displays these as POI markers. Track points whose `name != nil` are also emitted as course points for backwards compatibility.
    ///   - totalDistance: Course total distance in meters.
    public static func encode(
        name: String,
        sport: UInt8,
        waypoints: [FITCourseWaypoint],
        pointsOfInterest: [FITCourseWaypoint] = [],
        totalDistance: Double
    ) -> Data {
        var body = Data()

        // 1. File ID
        encodeFileIDMessage(into: &body)

        // 2. Course
        encodeCourseMessage(name: name, sport: sport, into: &body)

        // 3. Lap
        encodeLapMessage(waypoints: waypoints, totalDistance: totalDistance, into: &body)

        // 4. Records — one per track waypoint
        for waypoint in waypoints {
            encodeRecordMessage(waypoint: waypoint, into: &body)
        }

        // 5. Course points (POIs) — emit definition once, then one data msg per point
        let namedTrackPoints = waypoints.filter { $0.name != nil }
        let allCoursePoints = namedTrackPoints + pointsOfInterest
        if !allCoursePoints.isEmpty {
            encodeCoursePointDefinition(into: &body)
            for point in allCoursePoints {
                encodeCoursePointMessage(waypoint: point, into: &body)
            }
        }

        return buildFITFile(body: body)
    }

    // MARK: - FIT File Structure

    private static func buildFITFile(body: Data) -> Data {
        var file = Data()

        // Header (14 bytes: 12 fixed fields + 2-byte header CRC)
        let headerSize: UInt8 = 14
        let protocolVersion: UInt8 = 16
        let profileVersion: UInt16 = 2134
        file.append(headerSize)
        file.append(protocolVersion)
        file.appendUInt16LE(profileVersion)
        file.appendUInt32LE(UInt32(body.count))
        file.append(contentsOf: Data(".FIT".utf8))  // 4 bytes: 0x2E 0x46 0x49 0x54

        // Header CRC over the 12 preceding bytes. 0x0000 is spec-allowed ("not
        // computed"), but the watch indexer prefers a real value — it's also
        // what Garmin's own encoder emits.
        let headerCRC = computeFITCRC(file)
        file.appendUInt16LE(headerCRC)

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

        // FIT profile: file_id (mesg_num=0)
        //   0  type           uint8
        //   1  manufacturer   uint16
        //   2  product        uint16
        //   3  serial_number  uint32z
        //   4  time_created   date_time (uint32)
        defMsg.append(0); defMsg.append(1); defMsg.append(0)
        defMsg.append(1); defMsg.append(2); defMsg.append(0x84)
        defMsg.append(2); defMsg.append(2); defMsg.append(0x84)
        defMsg.append(3); defMsg.append(4); defMsg.append(0x8C)  // serial_number is uint32z (0x8C)
        defMsg.append(4); defMsg.append(4); defMsg.append(0x86)

        encodeDefinitionMessageHeader(&defMsg, localType: 0)
        body.append(defMsg)

        // Data message (local type 0) — order matches definition: type, mfr, product, serial, time
        var dataMsg = Data()
        dataMsg.append(6)                           // type = COURSE
        dataMsg.appendUInt16LE(255)                 // manufacturer = development (255)
        dataMsg.appendUInt16LE(0)                   // product (0 ok for development manufacturer)
        dataMsg.appendUInt32LE(0)                   // serial_number = 0 (invalid for uint32z)
        let timestamp = UInt32(Date().timeIntervalSince(FITTimestamp.epoch))
        dataMsg.appendUInt32LE(timestamp)           // time_created

        encodeDataMessageHeader(&dataMsg, localType: 0)
        body.append(dataMsg)
    }

    private static func encodeCourseMessage(name: String, sport: UInt8, into body: inout Data) {
        // FIT profile: course (mesg_num=31)
        //   4  sport      enum (uint8)
        //   5  name       string (16 bytes)
        //   6  capabilities uint32z
        var defMsg = Data()
        defMsg.append(0)  // reserved
        defMsg.append(0)  // architecture (LE)
        defMsg.appendUInt16LE(31)  // global message type (course)
        defMsg.append(2)  // numFields

        defMsg.append(4); defMsg.append(1); defMsg.append(0)   // sport
        defMsg.append(5); defMsg.append(16); defMsg.append(7)  // name (string, 16)

        encodeDefinitionMessageHeader(&defMsg, localType: 1)
        body.append(defMsg)

        // Data message (local type 1) — same order: sport, name
        var dataMsg = Data()
        dataMsg.append(sport)
        dataMsg.append(contentsOf: padString(name, to: 16))

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

        // FIT profile: lap (mesg_num=19)
        //   253 timestamp           date_time
        //   0   event               enum
        //   1   event_type          enum
        //   2   start_time          date_time
        //   3   start_position_lat  sint32 (semicircles)
        //   4   start_position_long sint32 (semicircles)
        //   7   total_elapsed_time  uint32 (scale 1000, units s)
        //   9   total_distance      uint32 (scale 100,  units m → cm)
        let fields: [(UInt8, UInt8, UInt8)] = [
            (253, 4, 0x86),  // timestamp
            (0, 1, 0),       // event
            (1, 1, 0),       // event_type
            (2, 4, 0x86),    // start_time
            (3, 4, 0x85),    // start_position_lat
            (4, 4, 0x85),    // start_position_long
            (7, 4, 0x86),    // total_elapsed_time (ms)
            (9, 4, 0x86),    // total_distance (cm)
        ]

        for (fieldNum, size, baseType) in fields {
            defMsg.append(fieldNum)
            defMsg.append(size)
            defMsg.append(baseType)
        }

        encodeDefinitionMessageHeader(&defMsg, localType: 2)
        body.append(defMsg)

        // Data message (local type 2) — order matches definition above
        var dataMsg = Data()
        let timestamp = UInt32(Date().timeIntervalSince(FITTimestamp.epoch))
        let firstWaypoint = waypoints.first

        dataMsg.appendUInt32LE(timestamp)                                            // timestamp
        dataMsg.append(0)                                                            // event = TIMER
        dataMsg.append(0)                                                            // event_type = START
        dataMsg.appendUInt32LE(timestamp)                                            // start_time
        dataMsg.appendInt32LE(degreesToSemicircles(firstWaypoint?.latitude ?? 0))    // start_position_lat
        dataMsg.appendInt32LE(degreesToSemicircles(firstWaypoint?.longitude ?? 0))   // start_position_long
        dataMsg.appendUInt32LE(0)                                                    // total_elapsed_time (ms) — 0 for static course
        dataMsg.appendUInt32LE(UInt32(totalDistance * 100))                          // total_distance (cm)

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

            // FIT profile: record (mesg_num=20)
            //   253 timestamp     date_time
            //   0   position_lat  sint32 (semicircles)
            //   1   position_long sint32 (semicircles)
            //   2   altitude      uint16 (scale 5, offset 500, units m)
            //   4   cadence       uint8
            //   5   distance      uint32 (scale 100, units m → cm)
            let fields: [(UInt8, UInt8, UInt8)] = [
                (253, 4, 0x86),  // timestamp
                (0, 4, 0x85),    // position_lat
                (1, 4, 0x85),    // position_long
                (2, 2, 0x84),    // altitude
                (4, 1, 0),       // cadence
                (5, 4, 0x86),    // distance
            ]

            for (fieldNum, size, baseType) in fields {
                defMsg.append(fieldNum)
                defMsg.append(size)
                defMsg.append(baseType)
            }

            encodeDefinitionMessageHeader(&defMsg, localType: 3)
            body.append(defMsg)
        }

        // Data message (local type 3) — order matches definition above
        var dataMsg = Data()
        let timestamp = UInt32(Date().timeIntervalSince(FITTimestamp.epoch))
        dataMsg.appendUInt32LE(timestamp)                                       // timestamp
        dataMsg.appendInt32LE(degreesToSemicircles(waypoint.latitude))          // position_lat
        dataMsg.appendInt32LE(degreesToSemicircles(waypoint.longitude))         // position_long
        dataMsg.appendUInt16LE(encodeAltitude(waypoint.altitude ?? 0))          // altitude
        dataMsg.append(0xFF)                                                    // cadence (invalid)
        dataMsg.appendUInt32LE(UInt32(waypoint.distanceFromStart * 100))        // distance (cm)

        encodeDataMessageHeader(&dataMsg, localType: 3)
        body.append(dataMsg)
    }

    private static func encodeCoursePointDefinition(into body: inout Data) {
        // FIT profile: course_point (mesg_num=32)
        //   253 timestamp     date_time
        //   1   position_lat  sint32 (semicircles)
        //   2   position_long sint32 (semicircles)
        //   3   distance      uint32 (scale 100, units m → cm)
        //   4   name          string (16)
        //   5   type          enum (course_point)
        var defMsg = Data()
        defMsg.append(0)
        defMsg.append(0)
        defMsg.appendUInt16LE(32)
        defMsg.append(6)

        let fields: [(UInt8, UInt8, UInt8)] = [
            (253, 4, 0x86),  // timestamp
            (1, 4, 0x85),    // position_lat
            (2, 4, 0x85),    // position_long
            (3, 4, 0x86),    // distance
            (4, 16, 7),      // name
            (5, 1, 0),       // type
        ]
        for (fieldNum, size, baseType) in fields {
            defMsg.append(fieldNum)
            defMsg.append(size)
            defMsg.append(baseType)
        }

        encodeDefinitionMessageHeader(&defMsg, localType: 4)
        body.append(defMsg)
    }

    private static func encodeCoursePointMessage(waypoint: FITCourseWaypoint, into body: inout Data) {
        // Data message (local type 4) — order matches definition above
        var dataMsg = Data()
        let timestamp = UInt32(Date().timeIntervalSince(FITTimestamp.epoch))
        dataMsg.appendUInt32LE(timestamp)                                       // timestamp
        dataMsg.appendInt32LE(degreesToSemicircles(waypoint.latitude))          // position_lat
        dataMsg.appendInt32LE(degreesToSemicircles(waypoint.longitude))         // position_long
        dataMsg.appendUInt32LE(UInt32(waypoint.distanceFromStart * 100))        // distance (cm)
        dataMsg.append(contentsOf: padString(waypoint.name ?? "", to: 16))      // name
        dataMsg.append(waypoint.coursePointType)                                // type

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
