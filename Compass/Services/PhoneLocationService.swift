import Foundation
import CoreLocation
import CompassBLE

@MainActor
final class PhoneLocationService: NSObject, CLLocationManagerDelegate {

    private let locationManager = CLLocationManager()

    /// Called with each encoded location message. Set by SyncCoordinator after connect.
    var sendMessage: (@Sendable (GFDIMessage) async -> Void)?

    private static let garminEpochOffset: TimeInterval = 631_065_600

    func startUpdating() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = 50
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
        // startUpdatingLocation immediately delivers the cached location via
        // didUpdateLocations, so no separate pushLastKnownLocation call is needed.
    }

    func stopUpdating() {
        locationManager.stopUpdatingLocation()
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let loc = locations.last else { return }
        Task { @MainActor in await self.push(loc) }
    }

    // MARK: - Private

    private func push(_ loc: CLLocation) async {
        let ts = garminTimestamp(from: loc.timestamp)
        AppLogger.location.info(String(format: "Pushing location lat=%.4f lon=%.4f hAcc=%.0fm ts=%u", loc.coordinate.latitude, loc.coordinate.longitude, loc.horizontalAccuracy, ts))
        let msg = PhoneLocationEncoder.encode(
            latDegrees: loc.coordinate.latitude,
            lonDegrees: loc.coordinate.longitude,
            altitude: Float(loc.altitude),
            hAccuracy: Float(loc.horizontalAccuracy),
            vAccuracy: Float(loc.verticalAccuracy > 0 ? loc.verticalAccuracy : loc.horizontalAccuracy),
            bearing: Float(loc.course > 0 ? loc.course : 0),
            speed: Float(max(0, loc.speed)),
            garminTimestamp: ts
        )
        await sendMessage?(msg)
    }

    private func garminTimestamp(from date: Date) -> UInt32 {
        UInt32(max(0, date.timeIntervalSince1970 - Self.garminEpochOffset))
    }
}
