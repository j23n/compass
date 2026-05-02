# WP-5 · Activity Detail View — Implementation Plan

## Current State

| Area | Current |
|---|---|
| Layout order | Header → Map (220 pt) → Stats grid → Chart picker |
| Stats grid | 2-column `LazyVGrid`; sport-specific cell sets |
| Chart metrics | HR, elevation, pace, speed; selected via pill picker |
| Chart interaction | Drag gesture; minimal tooltip (value + elapsed time string) |
| Chart axes | Y-axis auto-gridlines; no explicit X-axis domain or labels |
| Map ↔ chart link | Drag gesture → `highlightCoordinate` → map blue dot (implemented) |
| Sport coverage | `running, cycling, swimming, hiking, walking, strength, yoga, cardio, other` |
| Cycling altitude | Elevation chart available; **ascent/descent absent from stat cells** |

---

## Implementation Order

1. **Task 0 — Rename `totalCalories` → `activeCalories`** (prerequisite; model + parser + UI)
2. **Task 1 — Sport enum expansion** (foundation for all per-sport logic)
3. **Task 7 — Cycling altitude stat cells + chart availability audit** (highest-value data fix)
4. **Task 2 — Layout: stats before map + section headings** (structural)
5. **Task 3 — 3-column stat grid + StatCell compaction** (depends on Task 2 for context)
6. **Task 5 — Labelled chart axes** (independent; contained to chart modifiers)
7. **Task 4 — Consistent popout** (polish; depends on Task 5 for axis context)
8. **Task 6 — GPS ↔ graph link verification and fix** (investigation-first)

---

## Task 0 — Rename `totalCalories` → `activeCalories`

**Risk: LOW** — mechanical rename across 5 files; no logic change.

FIT session message (mesg 18) field 11 (`total_calories`) represents calories burned **during the activity** — it does NOT include resting metabolic rate (BMR) for the rest of the day. This is exactly what "active calories" means. The current property name `totalCalories` implies a daily total (including BMR), which is wrong. `MonitoringFITParser` already uses the name `activeCalories` for the equivalent field in monitoring messages (field 4) — align the activity model with this convention.

### `Activity.swift` (`CompassData` package)

```swift
// was:
public var totalCalories: Double
// init param:
totalCalories: Double

// becomes:
public var activeCalories: Double
// init param:
activeCalories: Double
```

### `ActivityFITParser.swift`

```swift
// was:
private static let fieldTotalCalories: UInt8 = 11      // kcal
let totalCalories = session[Self.fieldTotalCalories]?.doubleValue ?? 0
// init:
totalCalories: totalCalories

// becomes:
private static let fieldActiveCalories: UInt8 = 11     // kcal — active calories burned during session
let activeCalories = session[Self.fieldActiveCalories]?.doubleValue ?? 0
// init:
activeCalories: activeCalories
```

### `ActivityDetailView.swift`

```swift
// was:
activity.totalCalories > 0 ? "\(Int(activity.totalCalories))" : "--"
StatCell(title: "Calories", value: caloriesString, unit: "kcal")

// becomes:
activity.activeCalories > 0 ? "\(Int(activity.activeCalories))" : "--"
StatCell(title: "Active Cal", value: caloriesString, unit: "kcal")
```

Update also the preview stub at the bottom of `ActivityDetailView.swift`.

### `MockDataProvider.swift` and `CompassDataTests.swift`

Rename the `totalCalories:` argument label to `activeCalories:` in all `Activity(...)` call sites.

**Acceptance criteria:**
- Project compiles with zero errors after the rename
- Activity detail stat cell shows "Active Cal" label
- Values are unchanged (same field, same number)

---

## Task 1 — Sport Enum Expansion & Per-Sport Metrics Matrix

**Risk: LOW-MEDIUM** — enum expansion is additive; metrics matrix is pure UI logic.

### `Sport.swift` (`CompassData` package)

Add new cases with their FIT sport codes. These sport codes are the `sport` field values from FIT `session` message (message 18):

```swift
public enum Sport: Int, CaseIterable, Codable, Sendable {
    // existing
    case running       // fitSportCode: 1
    case cycling       // fitSportCode: 2
    case swimming      // fitSportCode: 5
    case hiking        // fitSportCode: 17
    case walking       // fitSportCode: 11
    case strength      // fitSportCode: 4 (fitness_equipment)
    case yoga          // fitSportCode: 62
    case cardio        // fitSportCode: 85
    // new
    case rowing        // fitSportCode: 15
    case kayaking      // fitSportCode: 41
    case skiing        // fitSportCode: 13
    case snowboarding  // fitSportCode: 14
    case sup           // fitSportCode: 37
    case climbing      // fitSportCode: 31
    case boating       // fitSportCode: 23
    case mtb           // fitSportCode: 2, sub_sport: 8 (mountain biking sub-sport of cycling)
    case other         // fitSportCode: 0
}
```

**MTB note:** MTB is FIT sport 2 (cycling) with sub_sport 8. The `ActivityFITParser` must read the `sub_sport` field from the session message and emit `.mtb` instead of `.cycling` when the combination matches. Add `subSportCode: UInt8?` handling in `ActivityFITParser.swift` at the session-message parsing site.

Update `fitSportCode` computed property. Add a `fitSubSportCode: UInt8?` property:

```swift
public var fitSportCode: UInt8 {
    switch self {
    case .running: return 1
    case .cycling, .mtb: return 2
    case .swimming: return 5
    case .walking: return 11
    case .skiing: return 13
    case .snowboarding: return 14
    case .rowing: return 15
    case .hiking: return 17
    case .climbing: return 31
    case .sup: return 37
    case .kayaking: return 41
    case .yoga: return 62
    case .cardio: return 85
    case .strength: return 4
    case .boating: return 23
    case .other: return 0
    }
}

public var fitSubSportCode: UInt8? {
    switch self {
    case .mtb: return 8
    default: return nil
    }
}
```

### `Sport+UI.swift` (app target)

Add `displayName`, `systemImage`, and `color` for each new case:

| Sport | displayName | systemImage | color |
|---|---|---|---|
| rowing | "Rowing" | `oar.2.crossed` | `.teal` |
| kayaking | "Kayaking" | `figure.water.fitness` | `.cyan` |
| skiing | "Skiing" | `figure.skiing.downhill` | `.indigo` |
| snowboarding | "Snowboarding" | `figure.snowboarding` | `.purple` |
| sup | "SUP" | `figure.surfing` | `.mint` |
| climbing | "Climbing" | `figure.climbing` | `.brown` |
| boating | "Boating" | `sailboat` | `.blue` |
| mtb | "Mountain Biking" | `bicycle` | `.green` |

### Per-Sport Metrics Matrix

Define this in `ActivityDetailView.swift` as an internal struct or function. It replaces the fragmented sport-specific `if/else` blocks currently spread through the stat cell and chart metric sections:

```swift
struct SportMetrics {
    let statCells: [StatCellSpec]
    let chartMetrics: [ChartMetric]
}

enum StatCellSpec {
    case distance, duration, pace, paceSwim, speed, avgHR, maxHR
    case ascentConditional, descentConditional  // only if data != nil
    case calories, cadence, strokeRate
}
```

Full matrix:

| Sport | Stat cells | Charts |
|---|---|---|
| running | distance, pace, avgHR, maxHR, ascent†, descent†, calories, cadence† | HR, elevation†, pace, cadence† |
| cycling | distance, speed, avgHR, maxHR, ascent†, descent†, calories | HR, elevation†, speed |
| mtb | distance, speed, avgHR, maxHR, ascent†, descent†, calories | HR, elevation†, speed |
| swimming | distance, paceSwim, avgHR, maxHR, calories | HR, pace |
| hiking | distance, pace, avgHR, maxHR, ascent†, descent†, calories | HR, elevation†, pace |
| walking | distance, pace, avgHR, maxHR, calories | HR, pace |
| rowing | distance, paceRow, avgHR, maxHR, calories, strokeRate† | HR, pace, cadence† |
| kayaking | distance, speed, avgHR, maxHR, calories | HR, speed |
| skiing | distance, speed, avgHR, maxHR, descent†, calories | HR, elevation†, speed |
| snowboarding | distance, speed, avgHR, maxHR, descent†, calories | HR, elevation†, speed |
| sup | distance, speed, avgHR, maxHR, calories | HR, speed |
| climbing | duration, avgHR, maxHR, ascent†, calories | HR, elevation† |
| boating | distance, speed, duration | speed |
| strength | duration, calories, avgHR, maxHR | HR |
| yoga | duration, avgHR, maxHR | HR |
| cardio | duration, calories, avgHR, maxHR | HR |
| other | distance, duration, avgHR, maxHR, calories | HR |

† = conditional on data presence (non-nil / non-zero in model or TrackPoints)

**Pace (rowing):** `paceRow` = seconds per 500 m: `500.0 / speed_ms`.

**Acceptance criteria:**
- A cycling activity with altitude data shows ascent + descent stat cells
- MTB activity maps to sport `.mtb` in ActivityDetailView title
- All new sport display names and icons compile without errors

---

## Task 7 — Cycling Altitude Stat Cells & Chart Availability Audit

**Risk: LOW** — purely additive data-display change; no model or parser changes.

### `ActivityDetailView.swift` — cycling stat case

After the Task 1 metrics matrix is in place, the cycling case automatically gains conditional ascent/descent from the matrix. However, verify that `activity.totalAscent` and `activity.totalDescent` are populated for cycling activities by the existing parser — inspect a real cycling FIT file in `FITFilesView`.

If the values are zero (parser not reading them for cycling), the issue is in `ActivityFITParser.swift`: check that the `lap` message handler reads field 21 (`total_ascent`) and field 22 (`total_descent`) for all sports, not just running.

### Chart metric selector audit

Current code makes `speed` available only for `.cycling`. Extend to `.mtb`, `.kayaking`, `.skiing`, `.snowboarding`, `.sup`, `.boating`, `.rowing`.

Elevation chart is already available for any sport with non-nil altitude data — this requires no change.

Add `cadence` as a new `ChartMetric` case:

```swift
case cadence  // .orange, figure.run  (rpm / spm depending on sport)
```

- Available when `trackPoints.contains { $0.cadence != nil }`
- Y-axis label: "rpm" for cycling/rowing, "spm" for running/walking

**Acceptance criteria:**
- Cycling activity with altitude data shows elevation chart option in pill picker
- Speed pill appears for all GPS-based non-running sports listed above
- Cadence pill appears for a running activity captured with a footpod

---

## Task 2 — Layout: Stats Before Map + Section Headings

**Risk: LOW** — view-body reorder only; no data or state changes.

### `ActivityDetailView.swift` — `body`

Current order in the `LazyVStack`:
1. Header card
2. `if hasGPS { MapRouteView ... }`
3. Stats card
4. Chart section

New order:
1. Header card
2. Stats card  ← moved up
3. `if hasGPS { MapRouteView ... }` ← moved below stats
4. Chart section

Add section headings as `.title3 .bold` text labels above each card (except the header):

```swift
// before stats card:
SectionHeading("Stats")

// before map:
if hasGPS {
    SectionHeading("Route")
    MapRouteView(...)
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 16))
}

// before charts:
SectionHeading("Charts")
```

`SectionHeading` is a local private view:

```swift
private struct SectionHeading: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.title3).fontWeight(.semibold)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}
```

**Acceptance criteria:**
- Stats grid is the first data section below the header
- Map appears below stats with "Route" heading
- Charts section has "Charts" heading above the pill picker

---

## Task 3 — 3-Column Stat Grid + StatCell Compaction

**Risk: LOW** — grid and cell layout change; purely visual.

### `ActivityDetailView.swift` — stat grid definition

```swift
// Replace:
LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12)
// With:
LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 10)
```

The 3-column layout reduces each cell's horizontal footprint by ~33%. StatCell's current `.title2 .bold` value label will truncate on narrow cells.

### `StatCell.swift` — value font size

Replace `.font(.title2)` with `.font(.headline)` (17 pt semibold) for the value label. Keep `.caption` for title and unit. Reduce cell vertical padding from 12 pt to 8 pt:

```swift
// was:
.padding(.vertical, 12)
// becomes:
.padding(.vertical, 8)
```

The `minimumScaleFactor(0.6)` already prevents clipping; with `.headline` this won't be needed for most values. Keep it as a safety net.

**Acceptance criteria:**
- All stat cells readable on iPhone 14 (390 pt width) without truncation
- 6-cell sport (running with ascent/descent) renders correctly in 3 columns with no overflow

---

## Task 5 — Labelled Chart Axes

**Risk: LOW** — Swift Charts axis modifier additions; no state changes.

### `ActivityDetailView.swift` — chart modifiers

**X-axis:** Fix the domain to `0...totalDuration` and label with elapsed time formatted as `MM:SS` or `H:MM`:

```swift
.chartXScale(domain: 0...totalDuration)
.chartXAxis {
    AxisMarks(values: .stride(by: strideInterval(totalDuration))) { value in
        AxisGridLine()
        AxisValueLabel {
            if let seconds = value.as(Double.self) {
                Text(formatElapsed(seconds))
                    .font(.caption2)
            }
        }
    }
}
```

```swift
private func strideInterval(_ duration: TimeInterval) -> Double {
    switch duration {
    case ..<600:   return 60      // < 10 min: every 1 min
    case ..<3600:  return 300     // < 1 hr:   every 5 min
    case ..<7200:  return 600     // < 2 hr:   every 10 min
    default:       return 1800    // 2 hr+:    every 30 min
    }
}
```

**Y-axis:** Add unit annotation to the existing axis labels. Each `ChartMetric` has a unit string:

```swift
var unit: String {
    switch self {
    case .heartRate: return "bpm"
    case .elevation: return "m"
    case .pace: return "/km"
    case .speed: return "km/h"
    case .cadence: return "rpm"
    }
}
```

```swift
.chartYAxis {
    AxisMarks { value in
        AxisGridLine()
        AxisValueLabel {
            if let v = value.as(Double.self) {
                Text(formatYValue(v)).font(.caption2)
            }
        }
    }
}
```

The y-axis label (the unit word, e.g. "bpm") is shown as a chart title annotation rather than a per-tick label, to avoid clutter:

```swift
.chartYAxisLabel(selectedMetric.unit, position: .leading)
```

**Acceptance criteria:**
- X-axis shows elapsed time labels that fit without overlap for a 45-minute run
- Y-axis shows "bpm" / "m" / "/km" / "km/h" label depending on selected metric
- A 3-hour activity shows 6 × 30-min x-axis ticks

---

## Task 4 — Consistent Popout (Match Health Graphs)

**Risk: LOW** — annotation styling only; no data-model changes.

The health graphs (`TrendChartView`) use a white card annotation with shadow, positioned `.top`, showing value + formatted date. Activity charts currently show the same data but with different styling.

### `ActivityDetailView.swift` — chart annotation

Current annotation (approximate from view body):
```swift
.annotation(position: .top) {
    VStack(spacing: 2) {
        Text(formatValue(v))
        Text(formatElapsed(t))
    }
    .font(.caption)
    .padding(6)
    .background(.white)
    .cornerRadius(8)
}
```

Replace with a component that matches `TrendChartView`'s callout card:

```swift
.annotation(position: .top, spacing: 6) {
    ChartCallout(
        value: formatYValue(selectedPoint.value),
        unit: selectedMetric.unit,
        label: formatCalloutTime(selectedPoint.elapsed, activity: activity)
    )
}
```

```swift
private struct ChartCallout: View {
    let value: String
    let unit: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value + " " + unit)
                .font(.subheadline).fontWeight(.semibold)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
    }
}
```

`formatCalloutTime` shows wall-clock time (from `activity.startDate + elapsed`) alongside elapsed (e.g., "10:42 AM · 12:35 in"):

```swift
private func formatCalloutTime(_ elapsed: Double, activity: Activity) -> String {
    let wallTime = activity.startDate.addingTimeInterval(elapsed)
    let timeStr = wallTime.formatted(date: .omitted, time: .shortened)
    let elapsedStr = formatElapsed(elapsed)
    return "\(timeStr) · \(elapsedStr) in"
}
```

**Acceptance criteria:**
- Tapping/dragging on activity chart shows the same card style as health graphs
- Callout stays on screen at all x positions (annotation position flips to `.bottom` if near top edge — use `.automatic` positioning)
- Both wall time and elapsed time are shown

---

## Task 6 — GPS Trace ↔ Graph Linking Verification

**Risk: MEDIUM** — requires investigation before implementation; map highlight path involves `@State` propagation across view boundaries.

### Investigation steps

1. In `ActivityDetailView.swift`, confirm the drag gesture handler updates `highlightedCoordinate` by inserting a temporary `Text("\(highlightedCoordinate?.latitude ?? 0)")` debug label.
2. Verify `MapRouteView` receives the updated binding and redraws the blue dot annotation. The fast-path in `MapRouteView.updateUIView` removes and re-adds the annotation for any non-nil highlight.
3. Confirm the `TrackPoint` lookup from elapsed time is correct: the lookup finds the nearest track point where `trackPoint.timestamp.timeIntervalSince(activity.startDate)` is closest to the dragged `chartRuleX` value.

### Likely failure mode

The current code likely uses:
```swift
let nearest = trackPoints.min(by: { abs($0.timestamp.timeIntervalSince(activity.startDate) - chartRuleX) < abs($1.timestamp.timeIntervalSince(activity.startDate) - chartRuleX) })
```

If `trackPoints` is not pre-sorted by timestamp, `min(by:)` returns a correct but potentially non-monotonic result. Sort `trackPoints` by `timestamp` once on view appear and cache it:

```swift
@State private var sortedTrackPoints: [TrackPoint] = []

.onAppear {
    sortedTrackPoints = activity.trackPoints.sorted { $0.timestamp < $1.timestamp }
}
```

Then use binary search or `first(where:)` on the sorted array for O(log n) performance.

### If chart-to-map is working but map-to-chart is not

The work item mentions "tapping a graph data point should highlight the corresponding position on the map; currently only the start/end points work." If a tap gesture is intended (in addition to drag), add a `.chartGesture` or `.onTapGesture` modifier:

```swift
.chartOverlay { proxy in
    GeometryReader { geo in
        Rectangle().fill(.clear).contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let x = value.location.x - geo[proxy.plotAreaFrame].origin.x
                        if let elapsed: Double = proxy.value(atX: x) {
                            updateHighlight(elapsed: elapsed)
                        }
                    }
                    .onEnded { _ in
                        // keep last highlighted point visible
                    }
            )
    }
}
```

`DragGesture(minimumDistance: 0)` handles both tap and drag.

**Acceptance criteria:**
- Dragging finger along the chart moves the blue dot along the GPS track in real time
- Releasing the drag leaves the last highlighted point visible (dot stays on map)
- Map does not flicker or re-layout during scrub
- Track points with no GPS data (lat/lon == 0) do not produce a highlight (skip them in the lookup)

---

## Files to Modify

| File | Tasks |
|---|---|
| `Packages/CompassData/Sources/CompassData/Models/Sport.swift` | 1 |
| `Packages/CompassFIT/Sources/CompassFIT/Parsers/ActivityFITParser.swift` | 1 (MTB sub-sport) |
| `Compass/Extensions/Sport+UI.swift` | 1 |
| `Compass/Views/Activity/ActivityDetailView.swift` | 2, 3, 4, 5, 6, 7 |
| `Compass/Views/Activity/StatCell.swift` | 3 |

---

## Known Limitations

- **MTB identification:** Garmin devices may not always set sub_sport correctly. Verify with a real MTB file; if sub_sport is unreliable, expose it as `.cycling` with a note in `ActivityRowView` (no action needed if no MTB activities are synced yet).
- **Cadence for swimming:** FIT swimming records may encode stroke rate in a different field than `cadence`. Verify with a swimming FIT file before enabling the cadence chart for swimming.
- **Boating / kayaking GPS:** Speed and distance for water sports may be sourced from GPS rather than sensors, making them sparse or absent for devices without GPS fix. The conditional stat cell approach (only show when data present) handles this gracefully.
- **Chart axis label collision:** On devices with small width (SE, 375 pt), 6 x-axis labels for a long activity may overlap. Use `.stride` with an adaptive interval or reduce label count with `desiredCount: 4`.
