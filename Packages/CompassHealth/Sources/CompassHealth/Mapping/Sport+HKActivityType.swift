#if canImport(HealthKit)
import HealthKit
import CompassData

extension Sport {

    /// HealthKit's enum of workout activity types. Mirrors the
    /// `fitSportCode` table in `Sport.swift`. HealthKit has no specific
    /// mountain-biking value, so MTB maps to `.cycling`.
    public var hkActivityType: HKWorkoutActivityType {
        switch self {
        case .running:      .running
        case .cycling:      .cycling
        case .mtb:          .cycling
        case .swimming:     .swimming
        case .walking:      .walking
        case .hiking:       .hiking
        case .strength:     .traditionalStrengthTraining
        case .yoga:         .yoga
        case .cardio:       .mixedCardio
        case .rowing:       .rowing
        case .kayaking:     .paddleSports
        case .skiing:       .downhillSkiing
        case .snowboarding: .snowboarding
        case .sup:          .paddleSports
        case .climbing:     .climbing
        case .boating:      .sailing
        case .other:        .other
        }
    }

    /// HealthKit distance quantity type if the sport accumulates distance;
    /// nil for indoor / non-distance sports (strength, yoga, etc.).
    public var hkDistanceType: HKQuantityType? {
        switch self {
        case .running, .walking, .hiking: HKQuantityType(.distanceWalkingRunning)
        case .cycling, .mtb:              HKQuantityType(.distanceCycling)
        case .swimming:                   HKQuantityType(.distanceSwimming)
        default:                          nil
        }
    }

    /// Best-effort indoor/outdoor flag used to set
    /// `HKWorkoutConfiguration.locationType`. Yoga and strength are indoor;
    /// everything else defaults to outdoor since Compass syncs from a GPS
    /// watch and "unknown" is rarely the right answer.
    public var hkLocationType: HKWorkoutSessionLocationType {
        switch self {
        case .strength, .yoga, .cardio: .indoor
        default:                        .outdoor
        }
    }
}
#endif
