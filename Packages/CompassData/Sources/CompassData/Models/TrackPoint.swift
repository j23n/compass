import Foundation
import SwiftData

/// Maps to HKWorkoutRoute + HKQuantitySamples
@Model
public final class TrackPoint {
    public var timestamp: Date
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double?
    public var heartRate: Int?
    public var cadence: Int?
    public var speed: Double?
    public var temperature: Double?

    public var activity: Activity?

    public init(
        timestamp: Date,
        latitude: Double,
        longitude: Double,
        altitude: Double? = nil,
        heartRate: Int? = nil,
        cadence: Int? = nil,
        speed: Double? = nil,
        temperature: Double? = nil,
        activity: Activity? = nil
    ) {
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.heartRate = heartRate
        self.cadence = cadence
        self.speed = speed
        self.temperature = temperature
        self.activity = activity
    }
}
