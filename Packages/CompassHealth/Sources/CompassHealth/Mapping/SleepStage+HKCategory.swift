#if canImport(HealthKit)
import HealthKit
import CompassData

extension SleepStageType {

    /// HealthKit's sleep-analysis values. Garmin's "light" maps to
    /// `.asleepCore` (Apple's term for non-deep, non-REM sleep). The other
    /// three are direct equivalents.
    public var hkSleepValue: HKCategoryValueSleepAnalysis {
        switch self {
        case .awake: .awake
        case .light: .asleepCore
        case .deep:  .asleepDeep
        case .rem:   .asleepREM
        }
    }
}
#endif
