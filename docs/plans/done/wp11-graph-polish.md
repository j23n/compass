# WP-11 · Graph Polish — Implementation Plan

Three Charts-related defects shared by Health and Activity views, plus the activity map↔chart synchronisation cleanup. They share a single root cause (re-layout on selection state change) and one shared fix pattern (pinned y-domain).

## Current State

| Area | File:line | Current behaviour |
|---|---|---|
| Day-view bucketing | `HealthDetailView.swift:49-69` | Hourly bucketing only for steps. HR / BB / stress / SpO2 / respiration fall through to raw scatter — fine for sparse data, ugly when there are 1k+ points. |
| Y-axis on health charts | `InteractiveTrendCard.swift`, `HealthDetailView.swift:322-326`, `TrendChartView.swift` | No explicit `chartYScale(domain:)`. SwiftUI Charts auto-scales every time the data array changes — including when the popover annotation is added/removed. |
| Y-axis on activity charts | `ActivityDetailView.swift` (chart blocks) | Same: no `chartYScale`, recomputed on every render. |
| Bar chart popover off-by-one | `InteractiveTrendCard.swift:267-280` | Touch-x → date via `proxy.value(atX:)`, then nearest bucket by `abs(bucket.date - date)`. Bar marks are drawn over `[bucket.date, bucket.end)` — at boundaries the nearest-by-centre lookup picks the *next* bucket. |
| Activity map ↔ chart | `ActivityDetailView.swift` + `MapRouteView.swift` | On scrub, `ActivityDetailView` linear-scans all `TrackPoint`s for the closest elapsed-second match and passes its lat/lon to `MapRouteView` as `highlightCoordinate`. Linear scan happens on every gesture event. |

---

## Implementation Order

1. **Task 1 — Pin y-domain on every interactive chart** (one shared helper; fixes "rescale on popover" and "y-label flicker on drag")
2. **Task 2 — Fix bar-chart selection** (interval containment, not nearest-by-centre)
3. **Task 3 — Hourly bucketing for all metrics on Day view**
4. **Task 4 — Pre-compute `(elapsedSecond → coord)` index for activity chart↔map**

Tasks 1–3 are within Health charts; Task 4 is the Activity-side counterpart and shares the y-domain pinning from Task 1.

---

## Task 1 — Pinned Y-Domain

**Risk: LOW** — additive `.chartYScale(...)` modifier; auto-scaling becomes deterministic.

### Why this fixes both bugs

- **Y-axis rescales when popover opens.** Annotations are extra `Mark`s in the chart's data domain. With auto-scaling, adding a `RuleMark` at the touched x-position (height = full y range) re-runs scale fitting if the rule's value affects the inferred y-extent. Pinning the y-domain to a value derived from the *underlying* data (not the visible marks) breaks the dependency.
- **Y-label flickers during drag.** Every drag event triggers a re-render. With auto-scaled y, transient label-spacing decisions inside Charts can change pixel-by-pixel. Pinned y-domain means consistent tick positions.

### Helper

`Compass/Components/ChartYDomain.swift`:

```swift
import Foundation

enum ChartYDomain {
    /// Returns a y-domain padded slightly above and below the data range,
    /// snapped to a "nice" interval for clean tick labels.
    /// Empty data → 0...1 (Charts default-ish).
    static func niceDomain(for values: [Double], paddingFraction: Double = 0.1) -> ClosedRange<Double> {
        guard let lo = values.min(), let hi = values.max(), hi > lo else {
            return 0...max(1, values.first ?? 1)
        }
        let span = hi - lo
        let pad = max(span * paddingFraction, 1)
        let low = (lo - pad).rounded(.down)
        let high = (hi + pad).rounded(.up)
        return low...high
    }

    /// For metrics that should always anchor at zero (steps, active minutes, sleep duration).
    static func zeroAnchored(for values: [Double], paddingFraction: Double = 0.1) -> ClosedRange<Double> {
        guard let hi = values.max(), hi > 0 else { return 0...1 }
        let pad = hi * paddingFraction
        return 0...((hi + pad).rounded(.up))
    }
}
```

### Apply at every chart site

Three call sites: `InteractiveTrendCard.swift`, `HealthDetailView.swift`, `TrendChartView.swift`, plus the per-metric chart inside `ActivityDetailView.swift`.

```swift
.chartYScale(domain: ChartYDomain.niceDomain(for: rawValues))
```

For sum metrics (steps, active minutes, sleep duration) use `zeroAnchored(for:)` instead — bar charts that don't start at zero are misleading.

`rawValues` is computed **once** from the source data, not from the visible marks plus selection annotation. This is the key invariant.

### Subtlety — domain stability across range changes

When the user toggles range (Week → Month), the data changes and the y-domain *should* recompute. That works correctly: the `.chartYScale(domain:)` value is a function of the source data; the modifier identity changes when the data does, so Charts updates the domain on data swap but not on selection change.

**Acceptance criteria**
- Touching a Health chart no longer animates the y-axis. Tick labels stay put.
- Dragging across a Health chart does not redraw the y-axis labels.
- Same in the Activity detail HR / Elevation / Speed charts.
- Range switches (Day → Week → Month → Year) still re-fit y to the new data.

---

## Task 2 — Bar-Chart Selection: Interval Containment

**Risk: LOW** — replaces a comparator with a predicate; bucket boundaries are already known.

### `InteractiveTrendCard.swift:267-280` (and the equivalent in `HealthDetailView.swift`)

Today:
```swift
let date: Date = proxy.value(atX: location.x) ?? Date()
let nearest = buckets.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) })
```

Replace with containment:
```swift
let date: Date = proxy.value(atX: location.x) ?? .now
let containing = buckets.first { bucket in
    bucket.date <= date && date < bucket.endDate
}
selectedPoint = containing ?? buckets.last
```

Each `TrendBucket` already carries its own `date` (start). Add an `endDate` field — for week/month buckets it's `+1 day`, for year buckets it's `+1 month`. This information is already implicit in the bucketing logic in `TrendChartView.swift:30-102`; expose it on the result type.

### Alternative: native `chartXSelection`

iOS 17+ provides `chartXSelection(value:)` which bins to the nearest bar mark automatically. Two-line change:

```swift
@State private var selectedDate: Date?

Chart { ... }
    .chartXSelection(value: $selectedDate)
```

`selectedDate` is the bar's start date — no nearest logic needed. Worth migrating to since it's strictly better, but verify it works with the existing custom callout (it should — selection state is just a date, callout positioning still uses `proxy.position(forX:)`).

Recommend the native API. The custom drag handler stays for the scatter (Day view) where there are no bins.

**Acceptance criteria**
- Tap precisely between two bars: the popover shows the bar that visually sits under the touch (its bin contains the touched x).
- Tap on the leftmost / rightmost bar: popover shows that bar (no off-end fallback to the nearest other bucket).

---

## Task 3 — Hourly Bucketing for Day View

**Risk: LOW** — extends an existing helper to all metrics, not just steps.

### `HealthDetailView.swift:49-69`

The hourly aggregation block currently dispatches on metric type to choose sum vs. average. Generalise:

```swift
private var dayBuckets: [TrendBucket] {
    let cal = Calendar.current
    let dayStart = cal.startOfDay(for: activeDateRange.lowerBound)
    return (0..<24).map { hour in
        let start = cal.date(byAdding: .hour, value: hour, to: dayStart)!
        let end   = cal.date(byAdding: .hour, value: 1, to: start)!
        let pointsInHour = filteredData.filter { $0.date >= start && $0.date < end }
        return TrendBucket(
            date: start,
            endDate: end,
            low:    pointsInHour.map(\.value).min() ?? 0,
            high:   pointsInHour.map(\.value).max() ?? 0,
            display: isSum
                ? pointsInHour.reduce(0) { $0 + $1.value }
                : (pointsInHour.isEmpty ? 0 : pointsInHour.map(\.value).reduce(0, +) / Double(pointsInHour.count))
        )
    }
}
```

`isSum` is the existing per-metric flag. Day view then renders bars instead of scatter for HR/BB/stress/SpO2/respiration as well (or keeps scatter and adds the bucket as a `RectangleMark` band — visual choice; recommend bars-with-low/high-range marks to match Week/Month/Year for visual consistency).

### Range-bar visualisation for non-sum metrics

For HR/BB/stress (range metrics with low/high), the existing Week/Month/Year view uses `BarMark(yStart: low, yEnd: high)` — keep that on Day too. For sum metrics, plain `BarMark(y: display)`.

This makes Day visually identical to the longer ranges, just denser.

**Acceptance criteria**
- Day view for HR shows 24 hourly bars (low–high range).
- Day view for steps shows 24 hourly bars (sum).
- Empty hours render as zero-height bars (or a thin baseline tick).
- Switching range Day → Week visibly aggregates 24 hourly bars to 7 daily bars without layout discontinuity.

---

## Task 4 — Pre-Computed Activity Map Index

**Risk: LOW** — caching only; correctness equivalent to today.

### Goal

On scrub of any chart in `ActivityDetailView`, look up the matching `TrackPoint` in O(log N) instead of O(N).

### `ActivityDetailView.swift`

A computed `let` (not `@State`) on the view, since `sortedTrackPoints` is already computed:

```swift
private var elapsedIndex: [(elapsed: TimeInterval, coord: CLLocationCoordinate2D?)] {
    sortedTrackPoints.map { tp in
        let coord: CLLocationCoordinate2D? = (tp.latitude == 0 && tp.longitude == 0)
            ? nil
            : CLLocationCoordinate2D(latitude: tp.latitude, longitude: tp.longitude)
        return (elapsed: tp.timestamp.timeIntervalSince(activity.startDate), coord: coord)
    }
}

/// Binary search for the nearest elapsed-second entry.
private func coord(atElapsed seconds: TimeInterval) -> CLLocationCoordinate2D? {
    var lo = 0, hi = elapsedIndex.count - 1
    guard hi >= 0 else { return nil }
    while lo < hi {
        let mid = (lo + hi) / 2
        if elapsedIndex[mid].elapsed < seconds { lo = mid + 1 } else { hi = mid }
    }
    // `lo` is the smallest index whose elapsed >= seconds; pick the closer of [lo-1, lo].
    let pick: Int
    if lo == 0 { pick = 0 }
    else {
        let prevDelta = abs(elapsedIndex[lo - 1].elapsed - seconds)
        let curDelta  = abs(elapsedIndex[lo].elapsed - seconds)
        pick = prevDelta < curDelta ? lo - 1 : lo
    }
    return elapsedIndex[pick].coord
}
```

`sortedTrackPoints` is already sorted by timestamp (verified in current code), so `elapsed` is monotonically increasing — binary search applies directly.

### Wire to the existing scrub handler

Wherever `selectedSecond: TimeInterval` is set today, also compute the highlight:

```swift
@State private var highlightCoord: CLLocationCoordinate2D?

.onChange(of: selectedSecond) { _, newValue in
    highlightCoord = newValue.flatMap { coord(atElapsed: $0) }
}

MapRouteView(trackPoints: sortedTrackPoints, highlightCoordinate: highlightCoord)
```

`MapRouteView` already updates the highlight annotation incrementally (per WP-7 / earlier plans) without rebuilding the route — no MapKit changes needed.

### Note on `elapsedIndex` cost

Computing the index every render is fine: it's an array of small tuples, length = number of track points (~5-10k for a long ride). SwiftUI re-renders the body when state changes, but the work is linear and cached by the let-binding within one render pass. If profiling later shows it's hot, lift it into an `@State` initialised in `.task`.

**Acceptance criteria**
- Scrubbing across the HR chart in a 5k-point activity moves the map highlight without visible lag.
- Highlight coordinate matches the nearest TrackPoint by elapsed-time.
- Activities with all-zero coordinates (indoor / treadmill) produce `nil` highlight; the map view falls back to its default state without crashing.

---

## Files to Modify

| File | Tasks |
|---|---|
| `Compass/Components/ChartYDomain.swift` | 1 (new) |
| `Compass/Components/TrendChartView.swift` | 1 (apply scale), 2 (bucket endDate field) |
| `Compass/Views/Health/InteractiveTrendCard.swift` | 1, 2 |
| `Compass/Views/Health/HealthDetailView.swift` | 1, 2, 3 |
| `Compass/Views/Activity/ActivityDetailView.swift` | 1 (per-metric charts), 4 |

---

## Verification

| Check | How |
|---|---|
| Y-axis stable on touch | Open HR Day card; tap-and-drag; observe y labels — no movement |
| Bar selection precise | Open Steps Week card; tap exactly between two bars; popover shows the one under the touch |
| Hourly day buckets | Open HR Day; expect 24 bars, low/high range visible |
| Activity map sync | Scrub HR chart on a long ride; map dot tracks smoothly with no frame-drop |

---

## Known Limitations

- **Charts auto-fit when data magnitude changes**. The pinned-domain helper recomputes when the data array changes, so range switches still rescale. There is no smooth interpolation between domains; that's a Charts-framework limit.
- **Bar selection without iOS 17**. We require iOS 18+ already (per `ARCHITECTURE.md`), so `chartXSelection` is available — no fallback path needed.
- **Day-view density on long sessions**. 24 hourly bars on a small phone screen is fine; if the design ever wants 96 bars (15-min buckets), revisit `dayBuckets` to take a `granularity` parameter.
- **Activity index recompute on every render**. Acceptable until profiling proves otherwise; mentioned above as a future tightening.
- **Indoor activities**. With no GPS, the activity-map highlight is always nil — no map sync to perform. The chart still scrubs; just no map effect.
