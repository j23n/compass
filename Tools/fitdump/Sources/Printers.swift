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
    let restHR    = result.restingHeartRateSamples
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
    if !restHR.isEmpty {
        let bpms = restHR.map(\.bpm)
        print(String(format: "resting HR samples : %-6d range %d\u{2013}%d bpm   span %@ \u{2192} %@",
                     restHR.count, bpms.min()!, bpms.max()!,
                     fmt(restHR.first!.timestamp), fmt(restHR.last!.timestamp)))
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
        print(String(format: "intervals          : %-6d step deltas total: %d",
                     intervals.count, totalSteps))
        let first = intervals.first!
        print(String(format: "first interval: %@   steps=%d  type=%d   kcal=%.1f",
                     fmt(first.timestamp), first.steps, first.activityType, first.activeCalories))
        let last = intervals.last!
        print(String(format: "last  interval: %@   steps=%d  type=%d   kcal=%.1f",
                     fmt(last.timestamp), last.steps, last.activityType, last.activeCalories))
    }
    if !result.dailyStepTotals.isEmpty {
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyy-MM-dd"
        dayFmt.timeZone = TimeZone(secondsFromGMT: 0)
        let sorted = result.dailyStepTotals.sorted { $0.key < $1.key }
        for (day, total) in sorted {
            print(String(format: "daily steps        : %@   %d", dayFmt.string(from: day), total))
        }
    }
    if !result.activeMinuteTimestamps.isEmpty {
        print(String(format: "active minutes     : %d (HR ≥ threshold)",
                     result.activeMinuteTimestamps.count))
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
    print(String(format: "raw:     %@ \u{2192} %@  (%@)",
                 fmt(result.startDate), fmt(result.endDate), fmtDuration(duration)))

    let sortedStages = result.stages.sorted { $0.startDate < $1.startDate }
    if let bounds = SleepStageResult.trimmedBounds(stages: sortedStages) {
        let trimmedDuration = bounds.end.timeIntervalSince(bounds.start)
        print(String(format: "trimmed: %@ \u{2192} %@  (%@)",
                     fmt(bounds.start), fmt(bounds.end), fmtDuration(trimmedDuration)))
    } else {
        print("trimmed: (no qualifying sleep run found)")
    }

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

// MARK: - Merged sleep (simulates the SyncCoordinator's per-night merge)

func dumpMergedSleep(urls: [URL], profile: DeviceProfile) async throws {
    let parser = SleepFITParser(profile: profile)
    var allStages: [SleepStageResult] = []
    var fileSummaries: [String] = []

    for url in urls {
        let data = try Data(contentsOf: url)
        guard let result = try await parser.parse(data: data) else {
            fileSummaries.append("  \(url.lastPathComponent): (no session)")
            continue
        }
        let dur = result.endDate.timeIntervalSince(result.startDate)
        fileSummaries.append("  \(url.lastPathComponent): \(fmt(result.startDate))\u{2192}\(fmt(result.endDate)) (\(fmtDuration(dur)), \(result.stages.count) stages)")
        allStages.append(contentsOf: result.stages)
    }
    allStages.sort { $0.startDate < $1.startDate }

    print("== Merged Sleep ==")
    print("input files (\(urls.count)):")
    for s in fileSummaries { print(s) }
    print("")
    print("merged stage count: \(allStages.count)")

    if let s = allStages.first, let e = allStages.last {
        let dur = e.endDate.timeIntervalSince(s.startDate)
        print("raw span:    \(fmt(s.startDate)) \u{2192} \(fmt(e.endDate))  (\(fmtDuration(dur)))")
    }

    if let bounds = SleepStageResult.trimmedBounds(stages: allStages) {
        let dur = bounds.end.timeIntervalSince(bounds.start)
        print("trimmed:     \(fmt(bounds.start)) \u{2192} \(fmt(bounds.end))  (\(fmtDuration(dur)))")
    } else {
        print("trimmed: (no qualifying sleep run found)")
    }

    var awake = 0, light = 0, deep = 0, rem = 0
    for s in allStages {
        switch s.stage {
        case .awake: awake += 1
        case .light: light += 1
        case .deep:  deep  += 1
        case .rem:   rem   += 1
        }
    }
    print("stage tally: awake=\(awake), light=\(light), deep=\(deep), rem=\(rem)  (one-minute stages, total=\(allStages.count) min)")
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
