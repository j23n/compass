import Testing
import Foundation
@testable import CompassHealth
import CompassData

@Suite("HealthDataSnapshot")
struct HealthDataSnapshotTests {

    @Test("Empty snapshot reports empty")
    func emptySnapshot() {
        let snap = HealthDataSnapshot()
        #expect(snap.isEmpty)
        #expect(snap.totalCount == 0)
    }

    @Test("Total count sums all sample arrays")
    func totalCount() {
        let now = Date()
        let snap = HealthDataSnapshot(
            heartRates: (0..<10).map { QuantityPoint(timestamp: now.addingTimeInterval(Double($0)), value: 60) },
            stepSamples: (0..<5).map { QuantityPoint(timestamp: now.addingTimeInterval(Double($0)), value: 100) }
        )
        #expect(snap.totalCount == 15)
        #expect(!snap.isEmpty)
    }

    @Test("Workout count contributes per trackpoint")
    func workoutContributesPerTrackpoint() {
        let now = Date()
        let trackPoints = (0..<100).map { i in
            TrackPointSnapshot(
                timestamp: now.addingTimeInterval(Double(i)),
                latitude: 0, longitude: 0, altitude: nil, heartRate: 120, speed: nil
            )
        }
        let activity = ActivitySnapshot(
            id: UUID(), sport: .running,
            startDate: now, endDate: now.addingTimeInterval(100),
            distance: 1000, duration: 100,
            activeCalories: nil, totalAscent: nil, totalDescent: nil,
            pauses: [], trackPoints: trackPoints, sourceFileName: nil
        )
        let snap = HealthDataSnapshot(activities: [activity])
        // 1 workout + 100 route points + 100 HR samples = 201
        #expect(snap.totalCount == 201)
    }
}
