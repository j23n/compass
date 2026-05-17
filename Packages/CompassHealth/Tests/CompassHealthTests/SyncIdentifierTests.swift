import Testing
import Foundation
@testable import CompassHealth
import CompassData

@Suite("SyncIdentifier")
struct SyncIdentifierTests {

    @Test("Workout identifier is stable across recomputation")
    func workoutStable() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(
            SyncIdentifier.workout(sport: .running, startDate: date) ==
            SyncIdentifier.workout(sport: .running, startDate: date)
        )
    }

    @Test("Workout identifier varies by sport")
    func workoutBySport() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(
            SyncIdentifier.workout(sport: .running, startDate: date) !=
            SyncIdentifier.workout(sport: .cycling, startDate: date)
        )
    }

    @Test("Identifier is second-granular")
    func secondGranularity() {
        let base = Date(timeIntervalSince1970: 1_700_000_000.0)
        let plus500ms = Date(timeIntervalSince1970: 1_700_000_000.5)
        // Both truncate to the same second epoch — explicit invariant.
        #expect(
            SyncIdentifier.heartRate(at: base) ==
            SyncIdentifier.heartRate(at: plus500ms)
        )
    }

    @Test("Identifier carries the compass prefix")
    func prefixed() {
        let id = SyncIdentifier.heartRate(at: Date())
        #expect(id.hasPrefix("compass."))
    }

    @Test("Workout HR identifiers differ across activities even at the same sample timestamp")
    func workoutHRDisambiguation() {
        let sample = Date(timeIntervalSince1970: 1_700_000_000)
        let activityA = Date(timeIntervalSince1970: 1_700_000_000 - 3600)
        let activityB = Date(timeIntervalSince1970: 1_700_000_000 - 7200)
        let a = SyncIdentifier.workoutHeartRate(sport: .running, startDate: activityA, sampleDate: sample)
        let b = SyncIdentifier.workoutHeartRate(sport: .running, startDate: activityB, sampleDate: sample)
        #expect(a != b)
    }

    @Test("Sleep stage identifiers nest under their session")
    func sleepStageNesting() {
        let sessionStart = Date(timeIntervalSince1970: 1_700_000_000)
        let stageStart = sessionStart.addingTimeInterval(3600)
        let id = SyncIdentifier.sleepStage(sessionStart: sessionStart, stageStart: stageStart)
        #expect(id.contains("\(Int(sessionStart.timeIntervalSince1970))"))
        #expect(id.contains("\(Int(stageStart.timeIntervalSince1970))"))
    }
}
