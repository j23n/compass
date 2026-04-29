import Foundation

/// Encodes a phone GPS fix into a GFDI PROTOBUF_RESPONSE message for the watch.
///
/// Wire structure (mirrors Gadgetbridge `GarminSupport.onSetGpsLocation`):
///
///   Smart [field 13] → CoreService [field 7] → LocationUpdatedNotification
///                                               [field 1] → LocationData
///                                                            [1] LatLon {sint32, sint32}
///                                                            [2] altitude (float, metres)
///                                                            [3] timestamp (uint32, Garmin epoch)
///                                                            [4] h_accuracy (float, metres)
///                                                            [5] v_accuracy (float, metres)
///                                                            [6] position_type (enum, 2=REALTIME_TRACKING)
///                                                            [9] bearing (float, degrees)
///                                                            [10] speed (float, m/s)
///
/// Coordinate scale: semicircles — `degrees × (2³¹ / 180)` — same as FIT sint32 lat/lon.
public enum PhoneLocationEncoder {

    private static let semicircleScale: Double = 2_147_483_648.0 / 180.0  // 2^31 / 180

    public static func encode(
        latDegrees: Double,
        lonDegrees: Double,
        altitude: Float,
        hAccuracy: Float,
        vAccuracy: Float,
        bearing: Float,
        speed: Float,
        garminTimestamp: UInt32
    ) -> GFDIMessage {
        let latSC = Int32(clamping: Int64(latDegrees * semicircleScale))
        let lonSC = Int32(clamping: Int64(lonDegrees * semicircleScale))

        var latLon = ProtoEncoder()
        latLon.writeSInt32(field: 1, value: latSC)
        latLon.writeSInt32(field: 2, value: lonSC)

        var locData = ProtoEncoder()
        locData.writeMessage(field: 1, body: latLon.data)
        locData.writeFloat(field: 2, value: altitude)
        locData.writeUInt32(field: 3, value: garminTimestamp)
        locData.writeFloat(field: 4, value: hAccuracy)
        locData.writeFloat(field: 5, value: vAccuracy)
        locData.writeEnum(field: 6, value: 2)   // REALTIME_TRACKING
        locData.writeFloat(field: 9, value: bearing)
        locData.writeFloat(field: 10, value: speed)

        var locNotif = ProtoEncoder()
        locNotif.writeMessage(field: 1, body: locData.data)

        var core = ProtoEncoder()
        core.writeMessage(field: 7, body: locNotif.data)

        var smart = ProtoEncoder()
        smart.writeMessage(field: 13, body: core.data)

        return GFDIMessage(type: .protobufResponse, payload: smart.data)
    }
}

