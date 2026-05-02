import Testing
import Foundation
@testable import CompassFIT

@Suite("Parser smoke tests")
struct ParserSmokeTests {

    @Test("MonitoringFITParser parses empty data without crashing")
    func monitoringEmpty() async throws {
        let parser = MonitoringFITParser()
        let result = try await parser.parse(data: Data())
        #expect(result.heartRateSamples.isEmpty)
        #expect(result.stressSamples.isEmpty)
        #expect(result.intervals.isEmpty)
        #expect(result.bodyBatterySamples.isEmpty)
        #expect(result.respirationSamples.isEmpty)
    }

    @Test("SleepFITParser returns nil for empty data")
    func sleepEmpty() async throws {
        let parser = SleepFITParser()
        let result = try await parser.parse(data: Data())
        #expect(result == nil)
    }

    @Test("MetricsFITParser returns no results for empty data")
    func metricsEmpty() async throws {
        let parser = MetricsFITParser()
        let results = try await parser.parse(data: Data())
        #expect(results.isEmpty)
    }

    @Test("ActivityFITParser returns nil for empty data")
    func activityEmpty() async throws {
        let parser = ActivityFITParser()
        let result = try await parser.parse(data: Data())
        #expect(result == nil)
    }
}
