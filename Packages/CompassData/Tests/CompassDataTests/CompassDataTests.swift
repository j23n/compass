import Testing
import Foundation
import SwiftData
@testable import CompassData

@MainActor
@Suite("CompassData Tests")
struct CompassDataTests {

    // MARK: - Helpers

    /// Creates an in-memory ModelContainer with all CompassData model types.
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Activity.self,
            TrackPoint.self,
            SleepSession.self,
            SleepStage.self,
            HeartRateSample.self,
            HRVSample.self,
            StressSample.self,
            BodyBatterySample.self,
            RespirationSample.self,
            StepCount.self,
            ConnectedDevice.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    // MARK: - Model Creation Tests

    @Test("Activity model can be created with all properties")
    func activityCreation() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let start = Date()
        let end = start.addingTimeInterval(3600)
        let activity = Activity(
            startDate: start,
            endDate: end,
            sport: .running,
            distance: 10_000,
            duration: 3600,
            totalCalories: 650,
            avgHeartRate: 155,
            maxHeartRate: 180,
            totalAscent: 120,
            totalDescent: 115
        )
        context.insert(activity)
        try context.save()

        let descriptor = FetchDescriptor<Activity>()
        let results = try context.fetch(descriptor)
        #expect(results.count == 1)
        #expect(results[0].sport == .running)
        #expect(results[0].distance == 10_000)
        #expect(results[0].avgHeartRate == 155)
    }

    @Test("TrackPoint links to Activity via inverse relationship")
    func trackPointRelationship() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let activity = Activity(
            startDate: Date(),
            endDate: Date().addingTimeInterval(1800),
            sport: .cycling,
            distance: 15_000,
            duration: 1800,
            totalCalories: 400
        )
        context.insert(activity)

        let point = TrackPoint(
            timestamp: Date(),
            latitude: 37.7749,
            longitude: -122.4194,
            altitude: 50,
            heartRate: 145,
            speed: 8.3,
            activity: activity
        )
        context.insert(point)
        try context.save()

        let descriptor = FetchDescriptor<Activity>()
        let activities = try context.fetch(descriptor)
        #expect(activities[0].trackPoints.count == 1)
        #expect(activities[0].trackPoints[0].latitude == 37.7749)
    }

    @Test("SleepSession with stages can be created")
    func sleepSessionCreation() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let start = Date()
        let session = SleepSession(
            startDate: start,
            endDate: start.addingTimeInterval(8 * 3600),
            score: 82
        )
        context.insert(session)

        let stages: [(SleepStageType, TimeInterval)] = [
            (.light, 1200),
            (.deep, 1800),
            (.light, 900),
            (.rem, 1500),
        ]
        var stageStart = start
        for (stageType, duration) in stages {
            let stageEnd = stageStart.addingTimeInterval(duration)
            let stage = SleepStage(
                startDate: stageStart,
                endDate: stageEnd,
                stage: stageType,
                session: session
            )
            context.insert(stage)
            stageStart = stageEnd
        }
        try context.save()

        let descriptor = FetchDescriptor<SleepSession>()
        let sessions = try context.fetch(descriptor)
        #expect(sessions.count == 1)
        #expect(sessions[0].stages.count == 4)
        #expect(sessions[0].score == 82)
    }

    @Test("HeartRateSample stores bpm and context")
    func heartRateSampleCreation() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let sample = HeartRateSample(timestamp: Date(), bpm: 72, context: .resting)
        context.insert(sample)
        try context.save()

        let descriptor = FetchDescriptor<HeartRateSample>()
        let results = try context.fetch(descriptor)
        #expect(results.count == 1)
        #expect(results[0].bpm == 72)
        #expect(results[0].context == .resting)
    }

    @Test("BodyBatterySample clamps level to 0-100")
    func bodyBatteryClamp() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let high = BodyBatterySample(timestamp: Date(), level: 150)
        let low = BodyBatterySample(timestamp: Date(), level: -10)
        context.insert(high)
        context.insert(low)
        try context.save()

        let descriptor = FetchDescriptor<BodyBatterySample>(sortBy: [SortDescriptor(\.level, order: .reverse)])
        let results = try context.fetch(descriptor)
        #expect(results[0].level == 100)
        #expect(results[1].level == 0)
    }

    @Test("StressSample clamps score to 0-100")
    func stressClamp() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let high = StressSample(timestamp: Date(), stressScore: 200)
        let low = StressSample(timestamp: Date(), stressScore: -5)
        context.insert(high)
        context.insert(low)
        try context.save()

        let descriptor = FetchDescriptor<StressSample>(sortBy: [SortDescriptor(\.stressScore, order: .reverse)])
        let results = try context.fetch(descriptor)
        #expect(results[0].stressScore == 100)
        #expect(results[1].stressScore == 0)
    }

    @Test("ConnectedDevice can be created and fetched")
    func connectedDeviceCreation() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let device = ConnectedDevice(
            name: "Test Watch",
            model: "Model X",
            lastSyncedAt: Date(),
            fitFileCursor: 42
        )
        context.insert(device)
        try context.save()

        let descriptor = FetchDescriptor<ConnectedDevice>()
        let results = try context.fetch(descriptor)
        #expect(results.count == 1)
        #expect(results[0].name == "Test Watch")
        #expect(results[0].fitFileCursor == 42)
    }

    // MARK: - Sport Enum Tests

    @Test("Sport enum provides correct display names and system images")
    func sportEnum() {
        #expect(Sport.running.displayName == "Running")
        #expect(Sport.running.systemImage == "figure.run")
        #expect(Sport.cycling.systemImage == "bicycle")
        #expect(Sport.swimming.systemImage == "figure.pool.swim")
    }

    // MARK: - SleepStageType Tests

    @Test("SleepStageType sort order is deep < rem < light < awake")
    func sleepStageOrder() {
        let sorted = SleepStageType.allStages.sorted { $0.sortOrder < $1.sortOrder }
        #expect(sorted == [.deep, .rem, .light, .awake])
    }

    // MARK: - MockDataProvider Tests

    @Test("MockDataProvider seeds expected number of activities")
    func mockActivities() throws {
        let container = try makeContainer()
        let context = container.mainContext
        MockDataProvider.seed(context: context)

        let descriptor = FetchDescriptor<Activity>()
        let activities = try context.fetch(descriptor)
        #expect(activities.count == 30)
    }

    @Test("MockDataProvider seeds 90 days of sleep sessions")
    func mockSleep() throws {
        let container = try makeContainer()
        let context = container.mainContext
        MockDataProvider.seed(context: context)

        let descriptor = FetchDescriptor<SleepSession>()
        let sessions = try context.fetch(descriptor)
        #expect(sessions.count == 90)

        // Each session should have stages
        for session in sessions {
            #expect(session.stages.count > 0)
        }
    }

    @Test("MockDataProvider seeds 90 days of step counts")
    func mockStepCounts() throws {
        let container = try makeContainer()
        let context = container.mainContext
        MockDataProvider.seed(context: context)

        let descriptor = FetchDescriptor<StepCount>()
        let counts = try context.fetch(descriptor)
        #expect(counts.count == 90)
    }

    @Test("MockDataProvider seeds heart rate samples every 15 min for 90 days")
    func mockHeartRate() throws {
        let container = try makeContainer()
        let context = container.mainContext
        MockDataProvider.seed(context: context)

        let descriptor = FetchDescriptor<HeartRateSample>()
        let samples = try context.fetch(descriptor)
        // 96 samples per day * 90 days = 8640
        #expect(samples.count == 8640)
    }

    @Test("MockDataProvider seeds a connected device")
    func mockDevice() throws {
        let container = try makeContainer()
        let context = container.mainContext
        MockDataProvider.seed(context: context)

        let descriptor = FetchDescriptor<ConnectedDevice>()
        let devices = try context.fetch(descriptor)
        #expect(devices.count == 1)
        #expect(devices[0].name == "Garmin Forerunner 265")
    }

    @Test("MockDataProvider is deterministic with seeded RNG")
    func mockDeterministic() throws {
        let container1 = try makeContainer()
        let context1 = container1.mainContext
        MockDataProvider.seed(context: context1)

        let container2 = try makeContainer()
        let context2 = container2.mainContext
        MockDataProvider.seed(context: context2)

        let desc = FetchDescriptor<StepCount>(sortBy: [SortDescriptor(\.date)])
        let steps1 = try context1.fetch(desc)
        let steps2 = try context2.fetch(desc)

        #expect(steps1.count == steps2.count)
        for i in 0..<steps1.count {
            #expect(steps1[i].steps == steps2[i].steps)
        }
    }

    // MARK: - Repository Tests

    @Test("ActivityRepository.latestActivities returns correct limit")
    func activityRepoLatest() throws {
        let container = try makeContainer()
        let context = container.mainContext
        MockDataProvider.seed(context: context)

        let repo = ActivityRepository(context: context)
        let latest5 = try repo.latestActivities(limit: 5)
        #expect(latest5.count == 5)

        // Verify sorted descending by startDate
        for i in 0..<(latest5.count - 1) {
            #expect(latest5[i].startDate >= latest5[i + 1].startDate)
        }
    }

    @Test("ActivityRepository.activity(byId:) finds the correct activity")
    func activityRepoById() throws {
        let container = try makeContainer()
        let context = container.mainContext
        MockDataProvider.seed(context: context)

        let repo = ActivityRepository(context: context)
        let all = try repo.latestActivities(limit: 1)
        guard let first = all.first else {
            Issue.record("No activities found")
            return
        }

        let found = try repo.activity(byId: first.id)
        #expect(found != nil)
        #expect(found?.id == first.id)
    }

    @Test("ActivityRepository.activitiesIn(dateRange:) filters correctly")
    func activityRepoDateRange() throws {
        let container = try makeContainer()
        let context = container.mainContext
        MockDataProvider.seed(context: context)

        let calendar = Calendar.current
        let now = Date()
        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: now)!
        let range = thirtyDaysAgo...now

        let repo = ActivityRepository(context: context)
        let recent = try repo.activitiesIn(dateRange: range)

        // All returned activities should be within the range
        for activity in recent {
            #expect(activity.startDate >= thirtyDaysAgo)
            #expect(activity.startDate <= now)
        }

        // Should be fewer than total
        let allActivities = try repo.latestActivities(limit: 100)
        #expect(recent.count <= allActivities.count)
    }

    @Test("SleepRepository.latestSleep returns most recent session")
    func sleepRepoLatest() throws {
        let container = try makeContainer()
        let context = container.mainContext
        MockDataProvider.seed(context: context)

        let repo = SleepRepository(context: context)
        let latest = try repo.latestSleep()
        #expect(latest != nil)
        #expect(latest!.score != nil)
    }

    @Test("HealthMetricsRepository.stepCounts(in:) returns daily counts")
    func healthRepoSteps() throws {
        let container = try makeContainer()
        let context = container.mainContext
        MockDataProvider.seed(context: context)

        let calendar = Calendar.current
        let now = Date()
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now))!

        let repo = HealthMetricsRepository(context: context)
        let counts = try repo.stepCounts(in: sevenDaysAgo...now)

        // Should have around 7 days of data (might be 7 or 8 depending on timing)
        #expect(counts.count >= 6)
        #expect(counts.count <= 9)

        for count in counts {
            #expect(count.steps > 0)
        }
    }

    @Test("DeviceRepository can save and fetch devices")
    func deviceRepo() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let repo = DeviceRepository(context: context)
        let device = ConnectedDevice(
            name: "Test Device",
            model: "Model Z",
            fitFileCursor: 0
        )
        try repo.saveDevice(device)

        let devices = try repo.connectedDevices()
        #expect(devices.count == 1)
        #expect(devices[0].name == "Test Device")
    }

    @Test("DeviceRepository.updateSyncCursor updates cursor and lastSyncedAt")
    func deviceRepoUpdateCursor() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let repo = DeviceRepository(context: context)
        let device = ConnectedDevice(
            name: "Sync Device",
            model: "Model S",
            fitFileCursor: 0
        )
        try repo.saveDevice(device)
        let deviceId = device.id

        try repo.updateSyncCursor(deviceId: deviceId, cursor: 99)

        let devices = try repo.connectedDevices()
        #expect(devices[0].fitFileCursor == 99)
        #expect(devices[0].lastSyncedAt != nil)
    }
}

// MARK: - Helpers for tests

extension SleepStageType {
    fileprivate static let allStages: [SleepStageType] = [.awake, .light, .deep, .rem]
}
