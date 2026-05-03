import Foundation
import CompassFIT
import CompassData

// MARK: - Shared formatters

private let dateFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    f.timeZone = TimeZone(identifier: "UTC")
    return f
}()

private let dateTimeFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    f.timeZone = TimeZone(identifier: "UTC")
    return f
}()

private func fmt(_ d: Date) -> String { dateFmt.string(from: d) }
private func fmtLong(_ d: Date) -> String { dateTimeFmt.string(from: d) }

private func fmtDuration(_ t: TimeInterval) -> String {
    let h = Int(t) / 3600
    let m = (Int(t) % 3600) / 60
    let s = Int(t) % 60
    return String(format: "%02d:%02d:%02d", h, m, s)
}

// MARK: - Activity

func dumpActivity(data: Data, profile: DeviceProfile) async throws {
    let parser = ActivityFITParser()
    guard let activity = try await parser.parse(data: data) else {
        print("== Activity ==")
        print("(no activity parsed)")
        return
    }

    let pts = activity.trackPoints
    let gpsCount = pts.filter { $0.latitude != 0 || $0.longitude != 0 }.count
    let altCount  = pts.filter { $0.altitude != nil }.count
    let spdCount  = pts.filter { $0.speed != nil }.count
    let cadCount  = pts.filter { $0.cadence != nil }.count
    let hrCount   = pts.filter { $0.heartRate != nil }.count

    print("== Activity ==")
    print("sport: \(activity.sport.rawValue)   start: \(fmtLong(activity.startDate)) UTC   duration: \(fmtDuration(activity.duration))")
    print(String(format: "distance: %.2f km  ascent: %g m  descent: %g m  calories: %g",
                 activity.distance / 1000,
                 activity.totalAscent ?? 0,
                 activity.totalDescent ?? 0,
                 activity.activeCalories ?? 0))
    if let avg = activity.avgHeartRate, let max = activity.maxHeartRate {
        print("avg/max HR: \(avg) / \(max) bpm")
    }
    print("track points: \(pts.count)   gps: \(gpsCount)   altitude: \(altCount)   speed: \(spdCount)   cadence: \(cadCount)   hr: \(hrCount)")

    if let first = pts.first {
        print(String(format: "first point: %@   %.4f, %.4f   alt %@   hr %@   spd %@",
                     fmtLong(first.timestamp),
                     first.latitude, first.longitude,
                     first.altitude.map { String(format: "%.1f", $0) } ?? "(nil)",
                     first.heartRate.map(String.init) ?? "(nil)",
                     first.speed.map { String(format: "%.1f m/s", $0) } ?? "(nil)"))
    }
    if let last = pts.last, pts.count > 1 {
        print(String(format: "last  point: %@   %.4f, %.4f   alt %@   hr %@   spd %@",
                     fmtLong(last.timestamp),
                     last.latitude, last.longitude,
                     last.altitude.map { String(format: "%.1f", $0) } ?? "(nil)",
                     last.heartRate.map(String.init) ?? "(nil)",
                     last.speed.map { String(format: "%.1f m/s", $0) } ?? "(nil)"))
    }
}

// MARK: - Monitoring

func dumpMonitoring(data: Data, profile: DeviceProfile) async throws {
    let parser = MonitoringFITParser(profile: profile)
    let result = try await parser.parse(data: data)

    let hr        = result.heartRateSamples
    let stress    = result.stressSamples
    let bb        = result.bodyBatterySamples
    let resp      = result.respirationSamples
    let spo2      = result.spo2Samples
    let intervals = result.intervals

    print("== Monitoring ==")

    if !hr.isEmpty {
        let bpms = hr.map(\.bpm)
        print(String(format: "heart rate samples : %-6d range %d\u{2013}%d bpm   span %@ \u{2192} %@",
                     hr.count, bpms.min()!, bpms.max()!,
                     fmt(hr.first!.timestamp), fmt(hr.last!.timestamp)))
    }
    if !stress.isEmpty {
        let vals = stress.map(\.stressScore)
        print(String(format: "stress samples     : %-6d range %d\u{2013}%d", stress.count, vals.min()!, vals.max()!))
    }
    if !bb.isEmpty {
        let vals = bb.map(\.level)
        print(String(format: "body battery       : %-6d range %d\u{2013}%d", bb.count, vals.min()!, vals.max()!))
    }
    if !resp.isEmpty {
        let vals = resp.map(\.breathsPerMinute)
        print(String(format: "respiration        : %-6d range %.1f\u{2013}%.1f bpm", resp.count, vals.min()!, vals.max()!))
    }
    if !spo2.isEmpty {
        let vals = spo2.map(\.percent)
        print(String(format: "SpO2               : %-6d range %d\u{2013}%d %%", spo2.count, vals.min()!, vals.max()!))
    }
    if !intervals.isEmpty {
        let totalSteps     = intervals.reduce(0) { $0 + $1.steps }
        let totalIntensity = intervals.reduce(0) { $0 + $1.intensityMinutes }
        print(String(format: "intervals          : %-6d steps total: %d   intensity-min total: %d",
                     intervals.count, totalSteps, totalIntensity))
        let first = intervals.first!
        print(String(format: "first interval: %@   steps=%d  type=%d  intensityMin=%d   kcal=%.1f",
                     fmt(first.timestamp), first.steps, first.activityType, first.intensityMinutes, first.activeCalories))
        let last = intervals.last!
        print(String(format: "last  interval: %@   steps=%d  type=%d  intensityMin=%d   kcal=%.1f",
                     fmt(last.timestamp), last.steps, last.activityType, last.intensityMinutes, last.activeCalories))
    }
}

// MARK: - Sleep

func dumpSleep(data: Data, profile: DeviceProfile) async throws {
    let parser = SleepFITParser(profile: profile)
    let result = try await parser.parse(data: data)

    print("== Sleep ==")
    guard let result else {
        print("(no session emitted)")
        return
    }

    let duration = result.endDate.timeIntervalSince(result.startDate)
    print(String(format: "session: %@ \u{2192} %@  (%@)",
                 fmt(result.startDate), fmt(result.endDate), fmtDuration(duration)))

    var parts: [String] = []
    if let score = result.score         { parts.append("score: \(score)") }
    if let rec   = result.recoveryScore { parts.append("recovery: \(rec)") }
    if let q     = result.qualifier     { parts.append("qualifier: \(q)") }
    if !parts.isEmpty { print(parts.joined(separator: "  ")) }

    let stages = result.stages
    print("stages (\(stages.count)):")
    for stage in stages {
        let dur = stage.endDate.timeIntervalSince(stage.startDate)
        print(String(format: "  %@\u{2013}%@   %-6@  (%@)",
                     fmt(stage.startDate), fmt(stage.endDate),
                     stage.stage.rawValue, fmtDuration(dur)))
    }
}

// MARK: - Metrics (HRV)

func dumpMetrics(data: Data) async throws {
    let parser = MetricsFITParser()
    let results = try await parser.parse(data: data)

    print("== HRV ==")
    guard !results.isEmpty else {
        print("(no HRV samples)")
        return
    }

    let rmssds = results.map { $0.rmssd * 1000 }
    print(String(format: "samples: %d   range %.0f\u{2013}%.0f ms   span %@ \u{2192} %@",
                 results.count,
                 rmssds.min()!, rmssds.max()!,
                 fmt(results.first!.timestamp),
                 fmt(results.last!.timestamp)))
    let first = results.first!
    print(String(format: "first: %@   rmssd=%.1f ms", fmt(first.timestamp), first.rmssd * 1000))
    let last = results.last!
    print(String(format: "last : %@   rmssd=%.1f ms", fmt(last.timestamp), last.rmssd * 1000))
}
