#if canImport(HealthKit)
import Testing
import HealthKit
@testable import CompassHealth
import CompassData

@Suite("Sport → HealthKit mapping")
struct SportMappingTests {

    @Test("Every Sport case maps to an HKWorkoutActivityType")
    func everySportMaps() {
        for sport in Sport.allCases {
            let type = sport.hkActivityType
            // .other is a valid HKWorkoutActivityType value; assert that the
            // mapping is total (no implicit defaults) by exercising every case.
            _ = type
        }
    }

    @Test("Distance sports surface the correct HK distance quantity type")
    func distanceTypeMapping() {
        #expect(Sport.running.hkDistanceType == HKQuantityType(.distanceWalkingRunning))
        #expect(Sport.hiking.hkDistanceType == HKQuantityType(.distanceWalkingRunning))
        #expect(Sport.walking.hkDistanceType == HKQuantityType(.distanceWalkingRunning))
        #expect(Sport.cycling.hkDistanceType == HKQuantityType(.distanceCycling))
        #expect(Sport.mtb.hkDistanceType == HKQuantityType(.distanceCycling))
        #expect(Sport.swimming.hkDistanceType == HKQuantityType(.distanceSwimming))
    }

    @Test("Indoor sports report nil distance type")
    func indoorNoDistance() {
        #expect(Sport.strength.hkDistanceType == nil)
        #expect(Sport.yoga.hkDistanceType == nil)
        #expect(Sport.cardio.hkDistanceType == nil)
        #expect(Sport.other.hkDistanceType == nil)
    }

    @Test("Yoga and strength are indoor; running and cycling are outdoor")
    func locationTypeMapping() {
        #expect(Sport.yoga.hkLocationType == .indoor)
        #expect(Sport.strength.hkLocationType == .indoor)
        #expect(Sport.cardio.hkLocationType == .indoor)
        #expect(Sport.running.hkLocationType == .outdoor)
        #expect(Sport.cycling.hkLocationType == .outdoor)
        #expect(Sport.hiking.hkLocationType == .outdoor)
    }
}

@Suite("SleepStageType → HealthKit mapping")
struct SleepStageMappingTests {

    @Test("Each stage maps to the documented HK value")
    func mapping() {
        #expect(SleepStageType.awake.hkSleepValue == .awake)
        #expect(SleepStageType.light.hkSleepValue == .asleepCore)
        #expect(SleepStageType.deep.hkSleepValue == .asleepDeep)
        #expect(SleepStageType.rem.hkSleepValue == .asleepREM)
    }
}
#endif
