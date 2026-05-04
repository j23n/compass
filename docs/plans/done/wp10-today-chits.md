# WP-10 · Today Chits — Implementation Plan

Three Today-view enhancements that share one underlying data shape:
- Per-chit "last reading" line with timestamp
- Replace the static sparkline with a 4-hour time-axis mini-chart
- Add a SpO2 chit
- Active-minutes chart sampled hourly (was: daily-only — needs a per-interval persistence layer)

## Current State

| Area | File:line | Current behaviour |
|---|---|---|
| Vitals chit content | `VitalsGridView.swift:184-237` | Card shell shows icon, label, current value, unit, plus a 24-pt-tall sparkline slot. **No timestamp, no relative-time text.** |
| Sparkline | `Components/SparklineChart.swift` | `PointMark` scatter, x = enumerated index (0…N), y = value. **No date axis** — purely positional. |
| Today data sources | `TodayView.swift:11-33, 71-155` | `@Query`-driven; HR/BB/stress/steps/active-min computed from samples / `StepCount`. |
| SpO2 in Today | — | Not present. `SpO2Sample` model exists in `CompassData` and is parsed (`SyncCoordinator.swift:501-503`); just not surfaced. |
| Active-minutes data path | `SyncCoordinator.swift:528-549`, `TodayView.swift:143-155` | Aggregated to per-day `StepCount.intensityMinutes`. **No per-interval persistence**, so an hourly chart is not derivable from the database today. |

---

## Implementation Order

1. **Task 1 — `IntensitySample` model + per-interval persistence** (data foundation; unblocks Task 4)
2. **Task 2 — Add SpO2 chit to `VitalsGridView`** (small, independent)
3. **Task 3 — `MetricCard` "last reading" line** (additive, shared by all chits)
4. **Task 4 — Time-windowed mini-chart** (replaces `SparklineChart` for Today)

Order matters: Task 1 lets Task 4 render an hourly active-minutes window; Task 3 is consumed by Task 4's combined chit layout.

---

## Task 1 — `IntensitySample` Model

**Risk: LOW** — additive model; no migration of existing rows because daily aggregates remain.

### `Packages/CompassData/Sources/CompassData/Models/IntensitySample.swift` (new)

```swift
import Foundation
import SwiftData

@Model
public final class IntensitySample {
    public var uuid: UUID = UUID()
    @Attribute(.unique) public var timestamp: Date
    public var minutes: Int               // 0 or 1 in current parser; future: fractional possible

    public init(timestamp: Date, minutes: Int) {
        self.timestamp = timestamp
        self.minutes = minutes
    }
}
```

Mirror `StepSample` exactly: independent (no relationship to `StepCount`), unique by timestamp, queryable by date range.

### `SyncCoordinator.swift` — write per-interval intensity

Inside the existing `for interval in results.intervals` loop (line 510):

```swift
for interval in results.intervals where interval.intensityMinutes > 0 {
    let ts = interval.timestamp
    var check = FetchDescriptor<CompassData.IntensitySample>(
        predicate: #Predicate<CompassData.IntensitySample> { $0.timestamp == ts }
    )
    check.fetchLimit = 1
    if (try? context.fetch(check))?.first == nil {
        context.insert(CompassData.IntensitySample(
            timestamp: ts,
            minutes: interval.intensityMinutes
        ))
    }
}
```

`StepCount.intensityMinutes` continues to exist for the Today headline (sum-per-day view); `IntensitySample` becomes the source for hourly bucketing.

### `ModelContainer` registration

Add `IntensitySample.self` to the `Schema(...)` list in `CompassApp.swift`. SwiftData migrates the schema additively — no migration plan needed for a brand-new entity.

**Acceptance criteria**
- After a sync that produces N intervals with `intensityMinutes == 1`, the count of `IntensitySample` rows equals N (minus duplicates from prior syncs).
- `StepCount` daily totals for the same day stay equal to the sum of `IntensitySample.minutes` for that day.

---

## Task 2 — SpO2 Chit

**Risk: LOW** — copy-paste of an existing chit pattern.

### `TodayView.swift`

Add a `@Query` and a derived `VitalsMetric`:

```swift
@Query(sort: \SpO2Sample.timestamp, order: .reverse) private var allSpO2: [SpO2Sample]

private var spo2Metric: VitalsMetric {
    let now = Date()
    let windowStart = now.addingTimeInterval(-4 * 3600)
    let recent = allSpO2.filter { $0.timestamp >= windowStart }
    let last = allSpO2.first   // .reverse sort → first is latest
    return VitalsMetric(
        current: last.map { Int($0.percent) },
        lastReadingAt: last?.timestamp,
        sparkline: recent.map { Double($0.percent) }.reversed(),
        history: weeklyAverage(of: allSpO2, value: \.percent)
    )
}
```

(`lastReadingAt` is added by Task 3.)

### `VitalsGridView.swift`

Add `let spo2: VitalsMetric` to the struct and a new card in the grid:

```swift
private var spo2Card: some View {
    NavigationLink {
        HealthDetailView(
            metricTitle: "Blood Oxygen",
            metricUnit: "%",
            color: .cyan,
            icon: "lungs.fill",
            data: spo2.history,
            useBarChart: false,
            valueFormatter: { String(format: "%.0f %%", $0) }
        )
    } label: {
        cardShell(icon: "lungs.fill", label: "Blood Oxygen", color: .cyan) {
            metricValue(spo2.current.map { "\($0)" }, unit: "%")
            chartSlot(!spo2.sparkline.isEmpty) { miniChart(for: spo2) }
        }
    }
    .buttonStyle(.plain)
}
```

Layout: with seven cards a 2-column grid leaves one card alone on the last row. Two options:

**A.** Accept the 4×2 layout with one orphan; the existing grid already does this when sleep is missing.

**B.** Move to a 3×3 layout for more compact density and put SpO2 next to HR / BB on the same row.

Recommend **A** for now — keeps each chit's tap target large. Revisit if the grid feels too tall.

### Health page

Also add a "Blood Oxygen" `InteractiveTrendCard` to `HealthView.swift` so the chit's `NavigationLink` lands on a Health-tab card the user can also reach directly. Same data feed.

**Acceptance criteria**
- After a sync producing SpO2 samples, Today shows a "Blood Oxygen" chit with the latest reading.
- Tapping it opens `HealthDetailView` with a scatter chart in `%`.
- Health tab also lists Blood Oxygen under the Vitals section.

---

## Task 3 — `MetricCard` "Last Reading" Line

**Risk: LOW** — additive label; no behaviour changes for existing callers if `lastReadingAt` is nil.

### Goal

Below the value, render one extra line:

```
43 bpm
small  54 minutes ago      (when < 60 minutes)
small  at 15:30            (when ≥ 60 minutes)
```

### Helper

Add `Compass/Extensions/Date+RelativeReading.swift`:

```swift
import Foundation

extension Date {
    /// "54 minutes ago" when within an hour, "at 15:30" otherwise.
    func relativeReadingDescription(now: Date = .now) -> String {
        let minutes = Int(now.timeIntervalSince(self) / 60)
        if minutes < 60 {
            let m = max(1, minutes)
            return "\(m) minute\(m == 1 ? "" : "s") ago"
        }
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return "at " + f.string(from: self)
    }
}
```

### `VitalsMetric` struct extension

```swift
struct VitalsMetric {
    let current: Int?
    let lastReadingAt: Date?            // new
    let sparkline: [Double]
    let history: [TrendDataPoint]
}
```

`TodayView` populates `lastReadingAt` from each query (e.g. `allHeartRateSamples.first?.timestamp`).

### `VitalsGridView.swift` — render the line

Inside `cardShell`'s VStack, between the value and the chart:

```swift
if let ts = lastReadingAt {
    Text(ts.relativeReadingDescription())
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
}
```

Sleep is the exception — no last-reading line; the sleep card stays as-is.

### Time freshness

The label is computed from `Date.now` at render time. On a long-lived view the text drifts. SwiftUI re-renders on data change; for clock-only redraws use a `TimelineView(.periodic(from: .now, by: 60))` wrapper around the chit body. Cheap (one re-render per minute, layout cached).

**Acceptance criteria**
- Each non-sleep chit shows a "N minutes ago" or "at HH:MM" line under the value.
- Without data, the line is absent (not "0 minutes ago").
- Switching tab away and back updates the relative time.

---

## Task 4 — Time-Windowed Mini-Chart

**Risk: MEDIUM** — replaces `SparklineChart` for Today chits with a Charts-based view that has an actual time axis. Health-tab and Activity sparkline callers (if any) keep using `SparklineChart`.

### Goal

A 24-pt-tall chart inside the chit:
- x-axis = the last 4 hours, ending at `Date.now`
- y-axis = the metric value, auto-scaled with explicit padding (no axis labels)
- Visualisation: continuous line for HR / BB / stress / SpO2 / respiration; bars for steps / active minutes

### `Compass/Components/MiniWindowChart.swift` (new)

```swift
import SwiftUI
import Charts

struct MiniWindowChart: View {
    enum Style { case line(color: Color), bars(color: Color) }

    let samples: [(date: Date, value: Double)]
    let window: TimeInterval
    let style: Style

    var body: some View {
        let endDate = Date.now
        let startDate = endDate.addingTimeInterval(-window)
        let visible = samples.filter { $0.date >= startDate && $0.date <= endDate }

        Chart {
            switch style {
            case .line(let color):
                ForEach(visible, id: \.date) { s in
                    LineMark(x: .value("t", s.date), y: .value("v", s.value))
                        .foregroundStyle(color)
                        .interpolationMethod(.monotone)
                }
            case .bars(let color):
                ForEach(visible, id: \.date) { s in
                    BarMark(x: .value("t", s.date), y: .value("v", s.value))
                        .foregroundStyle(color)
                }
            }
        }
        .chartXScale(domain: startDate...endDate)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: 24)
    }
}
```

The explicit `chartXScale` is what makes the visual position of the latest point meaningful (right edge = now), unlike the current scatter which is index-based.

### Active minutes — hourly buckets within the 4-hour window

For active minutes, the source is `IntensitySample` (Task 1). The mini-chart receives 4 `(hourStart, sumMinutesInHour)` points. `TodayView`:

```swift
private var activeMinutesSparklinePoints: [(Date, Double)] {
    let cal = Calendar.current
    let now = Date.now
    let bucketStart: (Int) -> Date = { hours in
        cal.date(bySettingHour: cal.component(.hour, from: now) - hours,
                 minute: 0, second: 0, of: now)!
    }
    return (0..<4).reversed().map { i in
        let start = bucketStart(i)
        let end = cal.date(byAdding: .hour, value: 1, to: start)!
        let sum = activeIntensitySamples
            .filter { $0.timestamp >= start && $0.timestamp < end }
            .reduce(0) { $0 + $1.minutes }
        return (start, Double(sum))
    }
}
```

Render with `.bars(color: .green)`.

### Steps — same per-hour pattern

Use existing `StepSample` rows; bucket by hour over the last 4 hours; render as bars.

### HR / BB / stress / SpO2 / respiration — pass raw samples

Render with `.line(...)`. Charts handles missing/sparse data gracefully via the explicit x-domain.

### `VitalsGridView.swift` — wire the new chart

```swift
private func miniChart(for metric: VitalsMetric, style: MiniWindowChart.Style) -> some View {
    MiniWindowChart(
        samples: metric.windowSamples,        // new field on VitalsMetric
        window: 4 * 3600,
        style: style
    )
}
```

Drop the existing `SparklineChart` call inside `chartSlot`.

### `VitalsMetric` final shape

```swift
struct VitalsMetric {
    let current: Int?
    let lastReadingAt: Date?
    let windowSamples: [(date: Date, value: Double)]   // last 4h, raw or hourly-bucketed
    let history: [TrendDataPoint]                      // for HealthDetailView push
}
```

The old `sparkline: [Double]` field goes away from Today; `SparklineChart` stays only for any other caller (verify via grep).

**Acceptance criteria**
- Each chit's mini-chart shows the right edge anchored to "now"; old data slides off the left edge as time passes (after re-render).
- HR/BB/stress chits show a continuous line; steps and active-minutes show four hourly bars.
- Active-minutes mini-chart renders the most recent four hours, sourced from `IntensitySample`.
- An empty 4-hour window renders an empty (but axis-correct) chart with no crash.

---

## Files to Modify

| File | Tasks |
|---|---|
| `Packages/CompassData/Sources/CompassData/Models/IntensitySample.swift` | 1 (new) |
| `Compass/App/CompassApp.swift` | 1 (add `IntensitySample.self` to Schema) |
| `Compass/App/SyncCoordinator.swift` | 1 (write per-interval intensity) |
| `Compass/Extensions/Date+RelativeReading.swift` | 3 (new) |
| `Compass/Components/MetricCard.swift` | 3 (last-reading line) |
| `Compass/Components/MiniWindowChart.swift` | 4 (new) |
| `Compass/Views/Today/VitalsGridView.swift` | 2 (SpO2 card), 3 (line), 4 (chart swap) |
| `Compass/Views/Today/TodayView.swift` | 1 (read intensity samples), 2 (SpO2 query), 3 (`lastReadingAt`), 4 (windowSamples) |
| `Compass/Views/Health/HealthView.swift` | 2 (Blood Oxygen card under Vitals) |

---

## Known Limitations

- **No min/avg/max overlay on the mini-chart.** Detail view still owns those — the chit is a glance, not a summary.
- **No tap-on-chit-to-show-details for the mini-chart itself.** The whole chit is already a `NavigationLink` to `HealthDetailView`; per-point inspection happens there.
- **SpO2 7th card layout.** Sticking with the 4×2 orphan; revisit when more chits land (e.g. respiration as its own chit).
- **`IntensitySample` storage cost.** ~96 rows/day if every interval has activity; ~35k rows/year. Negligible for SwiftData.
- **Backfill of `IntensitySample`.** New rows only — historical days that were synced before WP-10 will not gain hourly resolution. Reasonable: the headline daily total is unchanged, just the hourly chart is missing.
- **Clock drift in last-reading text.** `TimelineView(.periodic(...))` re-renders only while the view is on screen. When backgrounded the text doesn't update, but neither do the underlying samples — no inconsistency.
