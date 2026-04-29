import Foundation
import SwiftData

// MARK: - Seeded Random Number Generator

struct SeededRandomNumberGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        // xorshift64 algorithm
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

// MARK: - MockDataProvider

@MainActor
public struct MockDataProvider: Sendable {

    /// Seeds the given ModelContext with 90 days of realistic mock health data.
    /// Uses a deterministic random number generator (seed = 42) for reproducible output.
    public static func seed(context: ModelContext) {
        var rng = SeededRandomNumberGenerator(seed: 42)
        let calendar = Calendar.current
        let now = Date()
        guard let startDate = calendar.date(byAdding: .day, value: -90, to: calendar.startOfDay(for: now)) else {
            return
        }

        // --- Connected Device ---
        let device = ConnectedDevice(
            name: "Garmin Forerunner 265",
            model: "Forerunner 265",
            lastSyncedAt: now,
            fitFileCursor: 0
        )
        context.insert(device)

        // --- Activities (~30 over 90 days) ---
        seedActivities(context: context, startDate: startDate, calendar: calendar, rng: &rng)

        // --- Sleep Sessions (daily) ---
        seedSleepSessions(context: context, startDate: startDate, calendar: calendar, rng: &rng)

        // --- Heart Rate Samples (every 15 min) ---
        seedHeartRateSamples(context: context, startDate: startDate, calendar: calendar, rng: &rng)

        // --- HRV Samples (a few per day) ---
        seedHRVSamples(context: context, startDate: startDate, calendar: calendar, rng: &rng)

        // --- Body Battery Samples (every 15 min) ---
        seedBodyBatterySamples(context: context, startDate: startDate, calendar: calendar, rng: &rng)

        // --- Stress Samples (every 15 min) ---
        seedStressSamples(context: context, startDate: startDate, calendar: calendar, rng: &rng)

        // --- Respiration Samples (every 15 min) ---
        seedRespirationSamples(context: context, startDate: startDate, calendar: calendar, rng: &rng)

        // --- Step Counts (daily) ---
        seedStepCounts(context: context, startDate: startDate, calendar: calendar, rng: &rng)

        // --- Step Samples (intraday, every 5 min) ---
        seedStepSamples(context: context, startDate: startDate, calendar: calendar, rng: &rng)

        // --- Courses (sample routes) ---
        seedCourses(context: context, calendar: calendar, rng: &rng)

        try? context.save()
    }

    // MARK: - Activities

    private static func seedActivities(
        context: ModelContext,
        startDate: Date,
        calendar: Calendar,
        rng: inout SeededRandomNumberGenerator
    ) {
        let sportChoices: [Sport] = [.running, .running, .running, .cycling, .cycling, .hiking]
        let totalActivities = 30

        // Spread activities across 90 days with some randomness
        for i in 0..<totalActivities {
            let dayOffset = (i * 3) + Int.random(in: 0...2, using: &rng)
            guard let activityDate = calendar.date(byAdding: .day, value: dayOffset, to: startDate) else {
                continue
            }

            let sport = sportChoices[Int.random(in: 0..<sportChoices.count, using: &rng)]
            let hour = Int.random(in: 6...18, using: &rng)
            guard let activityStart = calendar.date(bySettingHour: hour, minute: Int.random(in: 0...59, using: &rng), second: 0, of: activityDate) else {
                continue
            }

            let durationMinutes: Double
            let distanceMeters: Double
            let calories: Double
            let avgHR: Int
            let maxHR: Int
            let ascent: Double?
            let descent: Double?

            switch sport {
            case .running:
                durationMinutes = Double.random(in: 25...70, using: &rng)
                let pace = Double.random(in: 4.5...6.5, using: &rng) // min/km
                distanceMeters = (durationMinutes / pace) * 1000.0
                calories = durationMinutes * Double.random(in: 10...14, using: &rng)
                avgHR = Int.random(in: 145...170, using: &rng)
                maxHR = avgHR + Int.random(in: 10...25, using: &rng)
                ascent = Double.random(in: 20...200, using: &rng)
                descent = Double.random(in: 20...200, using: &rng)
            case .cycling:
                durationMinutes = Double.random(in: 45...150, using: &rng)
                let speed = Double.random(in: 22...32, using: &rng) // km/h
                distanceMeters = (speed * durationMinutes / 60.0) * 1000.0
                calories = durationMinutes * Double.random(in: 8...12, using: &rng)
                avgHR = Int.random(in: 130...160, using: &rng)
                maxHR = avgHR + Int.random(in: 10...30, using: &rng)
                ascent = Double.random(in: 50...600, using: &rng)
                descent = Double.random(in: 50...600, using: &rng)
            case .hiking:
                durationMinutes = Double.random(in: 60...240, using: &rng)
                let speed = Double.random(in: 3...5, using: &rng) // km/h
                distanceMeters = (speed * durationMinutes / 60.0) * 1000.0
                calories = durationMinutes * Double.random(in: 6...10, using: &rng)
                avgHR = Int.random(in: 110...140, using: &rng)
                maxHR = avgHR + Int.random(in: 15...35, using: &rng)
                ascent = Double.random(in: 100...800, using: &rng)
                descent = Double.random(in: 100...800, using: &rng)
            default:
                durationMinutes = Double.random(in: 30...60, using: &rng)
                distanceMeters = 0
                calories = durationMinutes * Double.random(in: 6...10, using: &rng)
                avgHR = Int.random(in: 120...150, using: &rng)
                maxHR = avgHR + Int.random(in: 10...20, using: &rng)
                ascent = nil
                descent = nil
            }

            let durationSeconds = durationMinutes * 60
            let activityEnd = activityStart.addingTimeInterval(durationSeconds)

            let activity = Activity(
                startDate: activityStart,
                endDate: activityEnd,
                sport: sport,
                distance: distanceMeters,
                duration: durationSeconds,
                totalCalories: calories,
                avgHeartRate: avgHR,
                maxHeartRate: maxHR,
                totalAscent: ascent,
                totalDescent: descent
            )
            context.insert(activity)

            // Generate a few track points per activity
            let trackPointCount = max(5, Int(durationMinutes / 5))
            let baseLat = 37.7749 + Double.random(in: -0.05...0.05, using: &rng)
            let baseLon = -122.4194 + Double.random(in: -0.05...0.05, using: &rng)

            for j in 0..<trackPointCount {
                let fraction = Double(j) / Double(trackPointCount)
                let pointTime = activityStart.addingTimeInterval(durationSeconds * fraction)
                let lat = baseLat + Double.random(in: -0.01...0.01, using: &rng)
                let lon = baseLon + Double.random(in: -0.01...0.01, using: &rng)
                let alt = Double.random(in: 10...300, using: &rng)
                let hr = avgHR + Int.random(in: -15...15, using: &rng)
                let spd = distanceMeters / durationSeconds + Double.random(in: -0.5...0.5, using: &rng)

                let point = TrackPoint(
                    timestamp: pointTime,
                    latitude: lat,
                    longitude: lon,
                    altitude: alt,
                    heartRate: max(60, hr),
                    cadence: sport == .running ? Int.random(in: 150...190, using: &rng) : nil,
                    speed: max(0, spd),
                    activity: activity
                )
                context.insert(point)
            }
        }
    }

    // MARK: - Sleep Sessions

    private static func seedSleepSessions(
        context: ModelContext,
        startDate: Date,
        calendar: Calendar,
        rng: inout SeededRandomNumberGenerator
    ) {
        for dayOffset in 0..<90 {
            guard let dayDate = calendar.date(byAdding: .day, value: dayOffset, to: startDate) else {
                continue
            }

            // Sleep typically starts between 22:00 - 23:30
            let sleepHour = Int.random(in: 22...23, using: &rng)
            let sleepMinute = Int.random(in: 0...59, using: &rng)
            guard let sleepStart = calendar.date(bySettingHour: sleepHour, minute: sleepMinute, second: 0, of: dayDate) else {
                continue
            }

            // Sleep duration: 6-9 hours
            let sleepDurationMinutes = Double.random(in: 360...540, using: &rng)
            let sleepEnd = sleepStart.addingTimeInterval(sleepDurationMinutes * 60)

            let score = Int.random(in: 50...95, using: &rng)

            let session = SleepSession(
                startDate: sleepStart,
                endDate: sleepEnd,
                score: score
            )
            context.insert(session)

            // Generate realistic sleep stages
            // Typical cycle: Light -> Deep -> Light -> REM, repeating ~4-5 times
            var stageStart = sleepStart
            let cycleCount = Int(sleepDurationMinutes / 90) // ~90 min cycles
            let remainder = sleepDurationMinutes - Double(cycleCount) * 90.0

            for cycleIndex in 0..<cycleCount {
                // Each cycle: Light (15-25min) -> Deep (15-25min) -> Light (10-20min) -> REM (10-25min)
                // Deep sleep decreases in later cycles, REM increases
                let deepFactor = max(0.5, 1.0 - Double(cycleIndex) * 0.15)
                let remFactor = min(1.5, 1.0 + Double(cycleIndex) * 0.2)

                let lightDuration1 = Double.random(in: 15...25, using: &rng)
                let deepDuration = Double.random(in: 12...25, using: &rng) * deepFactor
                let lightDuration2 = Double.random(in: 8...18, using: &rng)
                let remDuration = Double.random(in: 10...25, using: &rng) * remFactor

                // Occasional brief awakenings between cycles
                let awakeDuration = cycleIndex > 0 ? Double.random(in: 0...5, using: &rng) : 0

                let stages: [(SleepStageType, Double)] = [
                    (.awake, awakeDuration),
                    (.light, lightDuration1),
                    (.deep, deepDuration),
                    (.light, lightDuration2),
                    (.rem, remDuration),
                ]

                for (stageType, duration) in stages {
                    if duration < 1 { continue }
                    let stageEnd = stageStart.addingTimeInterval(duration * 60)
                    let stage = SleepStage(
                        startDate: stageStart,
                        endDate: stageEnd,
                        stage: stageType,
                        session: session
                    )
                    context.insert(stage)
                    stageStart = stageEnd
                }
            }

            // Fill remainder with light sleep
            if remainder > 1 {
                let stage = SleepStage(
                    startDate: stageStart,
                    endDate: sleepEnd,
                    stage: .light,
                    session: session
                )
                context.insert(stage)
            }
        }
    }

    // MARK: - Heart Rate Samples

    private static func seedHeartRateSamples(
        context: ModelContext,
        startDate: Date,
        calendar: Calendar,
        rng: inout SeededRandomNumberGenerator
    ) {
        let interval: TimeInterval = 15 * 60 // 15 minutes
        for dayOffset in 0..<90 {
            guard let dayDate = calendar.date(byAdding: .day, value: dayOffset, to: startDate) else {
                continue
            }
            let dayStart = calendar.startOfDay(for: dayDate)

            for slotIndex in 0..<96 { // 96 slots of 15 min = 24 hours
                let timestamp = dayStart.addingTimeInterval(Double(slotIndex) * interval)
                let hour = calendar.component(.hour, from: timestamp)

                let bpm: Int
                let hrContext: HeartRateContext

                if hour >= 23 || hour < 6 {
                    // Night / sleep: lower HR
                    bpm = Int.random(in: 48...62, using: &rng)
                    hrContext = .sleep
                } else if hour >= 6 && hour < 8 {
                    // Early morning: resting
                    bpm = Int.random(in: 55...70, using: &rng)
                    hrContext = .resting
                } else if hour >= 12 && hour < 13 {
                    // Midday bump
                    bpm = Int.random(in: 65...85, using: &rng)
                    hrContext = .active
                } else {
                    // General daytime: resting with some variation
                    bpm = Int.random(in: 58...78, using: &rng)
                    hrContext = .resting
                }

                let sample = HeartRateSample(
                    timestamp: timestamp,
                    bpm: bpm,
                    context: hrContext
                )
                context.insert(sample)
            }
        }
    }

    // MARK: - HRV Samples

    private static func seedHRVSamples(
        context: ModelContext,
        startDate: Date,
        calendar: Calendar,
        rng: inout SeededRandomNumberGenerator
    ) {
        for dayOffset in 0..<90 {
            guard let dayDate = calendar.date(byAdding: .day, value: dayOffset, to: startDate) else {
                continue
            }

            // A few HRV readings per day: sleep, morning, evening
            let times: [(Int, Int, HeartRateContext)] = [
                (2, 30, .sleep),
                (7, 0, .resting),
                (22, 0, .resting),
            ]

            for (hour, minute, hrContext) in times {
                guard let timestamp = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: dayDate) else {
                    continue
                }

                let baseRmssd: Double
                switch hrContext {
                case .sleep:
                    baseRmssd = Double.random(in: 35...80, using: &rng)
                case .resting:
                    baseRmssd = Double.random(in: 25...65, using: &rng)
                case .active:
                    baseRmssd = Double.random(in: 15...40, using: &rng)
                }

                let sample = HRVSample(
                    timestamp: timestamp,
                    rmssd: baseRmssd,
                    context: hrContext
                )
                context.insert(sample)
            }
        }
    }

    // MARK: - Body Battery Samples

    private static func seedBodyBatterySamples(
        context: ModelContext,
        startDate: Date,
        calendar: Calendar,
        rng: inout SeededRandomNumberGenerator
    ) {
        let interval: TimeInterval = 15 * 60
        for dayOffset in 0..<90 {
            guard let dayDate = calendar.date(byAdding: .day, value: dayOffset, to: startDate) else {
                continue
            }
            let dayStart = calendar.startOfDay(for: dayDate)

            // Start of day: moderate level, recharges overnight, drains during day
            var currentLevel = Double.random(in: 40...60, using: &rng)

            for slotIndex in 0..<96 {
                let timestamp = dayStart.addingTimeInterval(Double(slotIndex) * interval)
                let hour = calendar.component(.hour, from: timestamp)

                if hour >= 23 || hour < 6 {
                    // Recharging during sleep: +1 to +3 per interval
                    currentLevel += Double.random(in: 1...3, using: &rng)
                } else if hour >= 6 && hour < 9 {
                    // Morning: slight drain
                    currentLevel -= Double.random(in: 0.5...2, using: &rng)
                } else if hour >= 12 && hour < 14 {
                    // Midday dip
                    currentLevel -= Double.random(in: 1...3, using: &rng)
                } else {
                    // General daytime drain
                    currentLevel -= Double.random(in: 0.5...2.5, using: &rng)
                }

                currentLevel = max(5, min(100, currentLevel))
                let sample = BodyBatterySample(
                    timestamp: timestamp,
                    level: Int(currentLevel)
                )
                context.insert(sample)
            }
        }
    }

    // MARK: - Stress Samples

    private static func seedStressSamples(
        context: ModelContext,
        startDate: Date,
        calendar: Calendar,
        rng: inout SeededRandomNumberGenerator
    ) {
        let interval: TimeInterval = 15 * 60
        for dayOffset in 0..<90 {
            guard let dayDate = calendar.date(byAdding: .day, value: dayOffset, to: startDate) else {
                continue
            }
            let dayStart = calendar.startOfDay(for: dayDate)

            for slotIndex in 0..<96 {
                let timestamp = dayStart.addingTimeInterval(Double(slotIndex) * interval)
                let hour = calendar.component(.hour, from: timestamp)

                let score: Int
                if hour >= 23 || hour < 6 {
                    // Low stress during sleep
                    score = Int.random(in: 5...20, using: &rng)
                } else if hour >= 9 && hour < 12 {
                    // Morning work: moderate stress
                    score = Int.random(in: 25...55, using: &rng)
                } else if hour >= 14 && hour < 17 {
                    // Afternoon: higher stress
                    score = Int.random(in: 30...65, using: &rng)
                } else {
                    // Other times: mild
                    score = Int.random(in: 15...40, using: &rng)
                }

                let sample = StressSample(
                    timestamp: timestamp,
                    stressScore: score
                )
                context.insert(sample)
            }
        }
    }

    // MARK: - Respiration Samples

    private static func seedRespirationSamples(
        context: ModelContext,
        startDate: Date,
        calendar: Calendar,
        rng: inout SeededRandomNumberGenerator
    ) {
        let interval: TimeInterval = 15 * 60
        for dayOffset in 0..<90 {
            guard let dayDate = calendar.date(byAdding: .day, value: dayOffset, to: startDate) else {
                continue
            }
            let dayStart = calendar.startOfDay(for: dayDate)

            for slotIndex in 0..<96 {
                let timestamp = dayStart.addingTimeInterval(Double(slotIndex) * interval)
                let hour = calendar.component(.hour, from: timestamp)

                let bpm: Double
                if hour >= 23 || hour < 6 {
                    // Sleep: slower breathing
                    bpm = Double.random(in: 12...16, using: &rng)
                } else {
                    // Awake: normal breathing
                    bpm = Double.random(in: 14...20, using: &rng)
                }

                let sample = RespirationSample(
                    timestamp: timestamp,
                    breathsPerMinute: bpm
                )
                context.insert(sample)
            }
        }
    }

    // MARK: - Step Samples (intraday)

    private static func seedStepSamples(
        context: ModelContext,
        startDate: Date,
        calendar: Calendar,
        rng: inout SeededRandomNumberGenerator
    ) {
        let interval: TimeInterval = 5 * 60 // 5-minute monitoring intervals
        for dayOffset in 0..<90 {
            guard let dayDate = calendar.date(byAdding: .day, value: dayOffset, to: startDate) else { continue }
            let dayStart = calendar.startOfDay(for: dayDate)

            for slotIndex in 0..<288 { // 24h × 12 slots/h
                let timestamp = dayStart.addingTimeInterval(Double(slotIndex) * interval)
                let hour = calendar.component(.hour, from: timestamp)

                let steps: Int
                switch hour {
                case 23, 0, 1, 2, 3, 4, 5:
                    steps = 0 // sleeping
                case 7...9:
                    steps = Int.random(in: 30...120, using: &rng)  // morning routine
                case 12...13:
                    steps = Int.random(in: 40...160, using: &rng)  // lunch walk
                case 17...19:
                    steps = Int.random(in: 50...200, using: &rng)  // evening walk
                default:
                    steps = Int.random(in: 5...60, using: &rng)
                }

                if steps > 0 {
                    context.insert(StepSample(timestamp: timestamp, steps: steps))
                }
            }
        }
    }

    // MARK: - Step Counts

    private static func seedStepCounts(
        context: ModelContext,
        startDate: Date,
        calendar: Calendar,
        rng: inout SeededRandomNumberGenerator
    ) {
        for dayOffset in 0..<90 {
            guard let dayDate = calendar.date(byAdding: .day, value: dayOffset, to: startDate) else {
                continue
            }
            let dayStart = calendar.startOfDay(for: dayDate)

            let steps = Int.random(in: 4000...15000, using: &rng)
            let intensityMinutes = Int.random(in: 10...60, using: &rng)
            let calories = Double(steps) * Double.random(in: 0.03...0.05, using: &rng)

            let stepCount = StepCount(
                date: dayStart,
                steps: steps,
                intensityMinutes: intensityMinutes,
                calories: calories
            )
            context.insert(stepCount)
        }
    }

    // MARK: - Courses

    private static func seedCourses(
        context: ModelContext,
        calendar: Calendar,
        rng: inout SeededRandomNumberGenerator
    ) {
        let now = Date()

        // Course 1: Bay Trail Loop (San Francisco area)
        var waypointsBay: [CourseWaypoint] = []
        let baseLatBay = 37.7749
        let baseLonBay = -122.4194
        let waypointCountBay = 12

        for i in 0..<waypointCountBay {
            let angle = Double(i) * 2.0 * .pi / Double(waypointCountBay)
            let lat = baseLatBay + 0.03 * sin(angle)
            let lon = baseLonBay + 0.03 * cos(angle)
            let distanceFromStart = Double(i) * (8500.0 / Double(waypointCountBay))
            let altitude = 10.0 + Double.random(in: 0...50, using: &rng)

            let waypoint = CourseWaypoint(
                order: i,
                latitude: lat,
                longitude: lon,
                altitude: altitude,
                name: i % 3 == 0 ? "Checkpoint \(i / 3 + 1)" : nil,
                distanceFromStart: distanceFromStart
            )
            waypointsBay.append(waypoint)
            context.insert(waypoint)
        }

        let course1 = Course(
            name: "Bay Trail Loop",
            importDate: calendar.date(byAdding: .day, value: -7, to: now) ?? now,
            sport: .running,
            totalDistance: 8500,
            totalAscent: 120,
            waypoints: waypointsBay
        )
        context.insert(course1)
        waypointsBay.forEach { $0.course = course1 }

        // Course 2: Urban Run (SF Downtown)
        var waypointsDown: [CourseWaypoint] = []
        let baseLatDown = 37.7940
        let baseLonDown = -122.3983
        let waypointCountDown = 8

        for i in 0..<waypointCountDown {
            let lat = baseLatDown + 0.02 * sin(Double(i) * 2.0 * .pi / Double(waypointCountDown))
            let lon = baseLonDown + 0.02 * cos(Double(i) * 2.0 * .pi / Double(waypointCountDown))
            let altitude = 15.0 + Double.random(in: 0...100, using: &rng)
            let distanceFromStart = Double(i) * (5200.0 / Double(waypointCountDown))

            let waypoint = CourseWaypoint(
                order: i,
                latitude: lat,
                longitude: lon,
                altitude: altitude,
                name: i % 2 == 0 ? "Turn \(i / 2 + 1)" : nil,
                distanceFromStart: distanceFromStart
            )
            waypointsDown.append(waypoint)
            context.insert(waypoint)
        }

        let course2 = Course(
            name: "Downtown Loop",
            importDate: calendar.date(byAdding: .day, value: -3, to: now) ?? now,
            sport: .running,
            totalDistance: 5200,
            totalAscent: 180,
            waypoints: waypointsDown
        )
        context.insert(course2)
        waypointsDown.forEach { $0.course = course2 }

        // Course 3: Hiking Trail
        var waypointsHike: [CourseWaypoint] = []
        let baseLatHike = 37.7549
        let baseLonHike = -122.4481
        let waypointCountHike = 10

        for i in 0..<waypointCountHike {
            let progression = Double(i) / Double(waypointCountHike - 1)
            let lat = baseLatHike + 0.025 * progression
            let lon = baseLonHike + 0.025 * progression
            let altitude = 100.0 + progression * 400.0 + Double.random(in: -20...20, using: &rng)
            let distanceFromStart = Double(i) * (6500.0 / Double(waypointCountHike - 1))

            let waypoint = CourseWaypoint(
                order: i,
                latitude: lat,
                longitude: lon,
                altitude: altitude,
                name: i == 0 ? "Trailhead" : i == waypointCountHike - 1 ? "Summit" : nil,
                distanceFromStart: distanceFromStart
            )
            waypointsHike.append(waypoint)
            context.insert(waypoint)
        }

        let course3 = Course(
            name: "Twin Peaks Trail",
            importDate: calendar.date(byAdding: .day, value: -14, to: now) ?? now,
            sport: .hiking,
            totalDistance: 6500,
            totalAscent: 450,
            waypoints: waypointsHike
        )
        context.insert(course3)
        waypointsHike.forEach { $0.course = course3 }
    }
}
