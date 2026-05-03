# WP-7 · Navigation & Today View — Implementation Plan

Cross-cutting navigation consistency: vitals navigation parity with Health, and a connection / sync indicator that is visible from every tab.

## Current State

| Area | Current |
|---|---|
| Today vitals navigation | Heart Rate / Body Battery / Stress / Steps / Active Minutes cards already wrap their `cardShell` in `NavigationLink { HealthDetailView(…) }` (`VitalsGridView.swift:46-166`). **Sleep card has no detail navigation** — it is the only chit without one (`VitalsGridView.swift:34-42`, comment "no detail view"). |
| HealthDetailView signature | `init(metricTitle, metricUnit, color, icon, data: [TrendDataPoint], useBarChart, initialRange, valueFormatter)` — pure metric viewer; no sleep-stage rendering. |
| Connection-status visibility | Rendered as a `connectionPill` only on TodayView (`TodayView.swift:200-229`) and as a row in SettingsView (`SettingsView.swift:28-47`). On the Activities, Health, and Courses tabs, no indicator is shown — the user has to switch back to Today to know the watch state. |
| Sync-progress visibility | `SyncCoordinator.state: SyncState` (`.idle / .syncing(description) / .completed(fileCount) / .failed(String)`) and `progress: Double` are exposed but **not rendered anywhere persistently**. The `CourseDetailView` upload section is currently the only place that surfaces `.syncing` / `.completed` mid-flight. |
| Tab structure | `ContentView` is a `TabView` with four tabs, each rooted in its own `NavigationStack` (`TodayView`, `ActivitiesListView`, `HealthView`, `CoursesListView`). |

---

## Implementation Order

1. **Task 1 — Sleep card → HealthDetailView navigation** (small, completes the vitals-navigation parity)
2. **Task 2a — Reusable `ConnectionSyncStatusView` component** (foundation for Task 2b)
3. **Task 2b — Wire the status view into all four tab toolbars** (apply via a `.connectionStatusToolbar()` view modifier)

---

## Task 1 — Sleep Card → HealthDetailView Navigation

**Risk: LOW** — wraps an existing card in a `NavigationLink`, mirrors the pattern already used by the other five vitals cards.

### Why this is the only remaining piece of "Today vitals chits → Health detail"

Five of six vitals cards (Heart Rate / Body Battery / Stress / Steps / Active Minutes) already do the right thing — each is wrapped in `NavigationLink { HealthDetailView(…) }` with `.buttonStyle(.plain)`. The work item's "rather than opening a bespoke inline view" wording predates that wiring; the only chit without parity now is **Sleep** (`VitalsGridView.swift:36-42`).

There is no separate sleep-detail screen anywhere in the codebase (verified: no `SleepDetailView` / `MetricDetailView` files exist). Sleep duration already renders in `HealthView` via `InteractiveTrendCard(useBarChart: true, color: .indigo)` — the same `HealthDetailView` path that Steps and Active Minutes use.

### `VitalsGridView.swift` — extend the API to take sleep history

Add one parameter so the caller can pass per-night sleep durations:

```swift
struct VitalsGridView: View {
    let sleepScore: Int?
    let sleepStages: [SleepStage]
    let sleepHistory: [TrendDataPoint]   // new — nightly hours over time

    let heartRate: VitalsMetric
    // …unchanged
}
```

### `VitalsGridView.swift` — wrap `sleepCard` in a `NavigationLink`

```swift
private var sleepCard: some View {
    NavigationLink {
        HealthDetailView(
            metricTitle: "Sleep",
            metricUnit: "hr",
            color: .indigo,
            icon: "bed.double.fill",
            data: sleepHistory,
            useBarChart: true,
            valueFormatter: { String(format: "%.1f hr", $0) }
        )
    } label: {
        cardShell(icon: "bed.double.fill", label: "Sleep", color: .purple) {
            metricValue(sleepScore.map { "\($0)" }, unit: nil)
            chartSlot(!sleepStages.isEmpty) { miniSleepBar }
        }
    }
    .buttonStyle(.plain)
}
```

(Card colour stays purple to match the existing icon; HealthDetailView's accent stays indigo to match the Health tab's "Sleep Duration" card. This visual split is intentional and mirrors how the Heart Rate card uses red while the Recovery section uses different colours per metric.)

### `TodayView.swift` — feed the new parameter

`TodayView` already computes `lastSleep` for the score. Add a sibling derived value mirroring `HealthView.sleepDurationData` (`HealthView.swift:44-48`):

```swift
private var sleepHistory: [TrendDataPoint] {
    allSleepSessions
        .map {
            TrendDataPoint(date: $0.startDate,
                           value: $0.endDate.timeIntervalSince($0.startDate) / 3600.0)
        }
        .sorted { $0.date < $1.date }
}
```

Pass it through in the `VitalsGridView(...)` call (`TodayView.swift:239-247`):

```swift
VitalsGridView(
    sleepScore: lastSleep?.score,
    sleepStages: lastSleep?.stages ?? [],
    sleepHistory: sleepHistory,                     // new
    heartRate: heartRateMetric,
    bodyBattery: bodyBatteryMetric,
    stress: stressMetric,
    steps: stepsMetric,
    activeMinutes: activeMinutesMetric
)
```

### Notes — what NOT to do here

- Do **not** create a new sleep-specific detail view. The work item explicitly says "reuse the existing page".
- Do **not** add a separate path for sleep-stage breakdown. The mini-bar on the card itself already shows stage proportion; the detail view shows duration trends, which is the standard Health-tab abstraction. If a future request adds per-night stage detail, that is a new screen, not part of WP-7.

**Acceptance criteria**
- Tapping the Sleep card on Today pushes onto the existing `HealthDetailView` with bar-chart sleep durations.
- Back-swipe returns to Today with scroll position preserved (default `NavigationStack` behaviour).
- The five other vitals cards behave exactly as before — no regressions.

---

## Task 2a — Reusable `ConnectionSyncStatusView` Component

**Risk: LOW** — new self-contained view; depends only on `SyncCoordinator` from `@Environment`.

### Goal

A single compact view that renders three states in priority order:

| Priority | Trigger | Render |
|---:|---|---|
| 1 | `state == .syncing(_)` | small `ProgressView` + percentage (`Int(progress * 100)%`) when `progress > 0`, otherwise the `.syncing(description)` truncated to ~24 chars |
| 2 | `state == .failed(msg)` (transient — show for ~5 s after, then revert to (3)) | red exclamation + "Sync failed" |
| 3 | otherwise | connection dot + name (matches existing `connectionPill` semantics) |

A successful `.completed` transitions through priority (3) immediately; the green pill is sufficient signal once data is in the views.

### New file: `Compass/Components/ConnectionSyncStatusView.swift`

```swift
import SwiftUI
import CompassBLE

/// Compact status indicator for the navigation bar.
/// Sync-in-progress takes precedence over connection state.
struct ConnectionSyncStatusView: View {
    @Environment(SyncCoordinator.self) private var sync

    var body: some View {
        HStack(spacing: 5) {
            switch displayMode {
            case .syncing(let label):
                ProgressView()
                    .controlSize(.mini)
                    .tint(.secondary)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                Text("Sync failed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

            case .connection(let dot, let label):
                Circle().fill(dot).frame(width: 8, height: 8)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Display mode resolution

    private enum Mode {
        case syncing(label: String)
        case failed
        case connection(dot: Color, label: String)
    }

    private var displayMode: Mode {
        if case .syncing(let desc) = sync.state {
            let label: String
            if sync.progress > 0 {
                label = "\(Int(sync.progress * 100))%"
            } else {
                label = abbreviated(desc)
            }
            return .syncing(label: label)
        }
        if case .failed = sync.state { return .failed }
        return .connection(dot: connectionDotColor, label: connectionLabel)
    }

    private var connectionDotColor: Color {
        switch sync.connectionState {
        case .connected:                .green
        case .connecting, .reconnecting: .orange
        case .disconnected, .failed:    .gray
        }
    }

    private var connectionLabel: String {
        switch sync.connectionState {
        case .connected(let name): name
        case .connecting:          "Connecting…"
        case .reconnecting:        "Reconnecting…"
        case .disconnected:        "Not connected"
        case .failed:              "Connection failed"
        }
    }

    /// "Listing activity files…" → "Listing activity…"
    /// Bounded to ~24 visible chars so the toolbar item never pushes the title.
    private func abbreviated(_ s: String) -> String {
        let trimmed = s.replacingOccurrences(of: " files...", with: "…")
                       .replacingOccurrences(of: "...", with: "…")
        return trimmed.count > 24 ? String(trimmed.prefix(23)) + "…" : trimmed
    }

    private var accessibilityDescription: String {
        switch displayMode {
        case .syncing(let l): return "Syncing, \(l)"
        case .failed:         return "Sync failed"
        case .connection(_, let label): return "Watch: \(label)"
        }
    }
}
```

### Notes

- `@Environment(SyncCoordinator.self)` matches the existing pattern (`TodayView`, `CourseDetailView`).
- Sync-in-progress wins because the user needs to know the watch is busy *before* knowing whether it is "connected".
- Truncation at 24 chars keeps the navigation bar from breaking the centred title on small phones; the existing sync descriptions ("Connecting...", "Listing activity files...", "Downloading file: 12345/45678 bytes", "Parsing data...") all fit comfortably.
- For "Downloading …", the `progress` value will be > 0, so we always show the percentage instead — this is the only case where the description is too long to fit.

---

## Task 2b — Wire the Status View into Every Tab

**Risk: LOW** — toolbar items per tab; each tab already owns its own `NavigationStack`.

### View modifier

Add a tiny modifier that places the status view in the navigation bar's leading position. Co-locate with `ConnectionSyncStatusView.swift`:

```swift
extension View {
    /// Adds the global connection / sync indicator to the leading edge of the
    /// nearest navigation bar. Apply once on the root view of each tab's NavigationStack.
    func connectionStatusToolbar() -> some View {
        toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ConnectionSyncStatusView()
            }
        }
    }
}
```

### Apply on every tab root

Each tab is a `NavigationStack { … }.navigationTitle(_)` — append the modifier directly under the existing `.toolbar { … }` calls.

| File | Where |
|---|---|
| `Compass/Views/Today/TodayView.swift` | After the existing `.toolbar { … }` block at line ~160 |
| `Compass/Views/Activity/ActivitiesListView.swift` | On the inner content view (next to its title/toolbar) |
| `Compass/Views/Health/HealthView.swift` | After `.navigationTitle("Health")` (line 165) |
| `Compass/Views/Courses/CoursesListView.swift` | On the inner `Group` after `.navigationTitle("Courses")` (line 23) |

### Remove the now-redundant `connectionPill` from TodayView

`TodayView`'s in-body `connectionPill` (line 200-229) duplicates the new toolbar item. Delete:

- The `connectionPill` `@ViewBuilder` (lines 200-211)
- The `connectionDotColor` and `connectionLabel` helpers (lines 213-229) — they live inside `ConnectionSyncStatusView` now.
- The `connectionPill` reference at line 187.

The `LazyVStack` in `dashboardContent` then opens directly with `vitalsSection`.

### Hide the indicator before pairing

If no device is paired, `ConnectionState` is `.disconnected` and the indicator would render "Not connected" on every tab. That is acceptable on Activities / Health / Courses (it tells the user why their data is stale), but on the Today empty-state screen it duplicates the existing `ContentUnavailableView` headline. Two options, in order of simplicity:

1. **Keep it everywhere**, including the empty Today state. The dot is small; the redundancy is minor.
2. Conditionally hide it on Today when `hasDevice == false` by gating the `.connectionStatusToolbar()` call.

Recommend (1). Keeps every tab consistent; the cost is one extra word in a corner that already says "No Device Connected".

### A note on placement

`.topBarLeading` puts the indicator opposite the existing trailing-edge controls (gear icon on Today, `+` on Courses, sport-filter on Activities). It does not collide with the centred title. On iPad / wide layouts the leading edge is also where the device-name pill from the system bar lives, so the placement reads as system status rather than view content.

**Acceptance criteria**
- Switching to Activities / Health / Courses tabs shows the same connection/sync indicator the user sees on Today.
- Triggering a sync (pull-to-refresh on Today, then immediately switching to Health) renders a spinner + percentage in the Health tab's nav bar that updates live.
- After a sync completes, the indicator returns to "Connected to {name}" within one runloop tick.
- TodayView no longer renders its own in-body `connectionPill`; the in-bar version is the single source of truth.
- Disconnecting the watch flips the dot to grey on every tab without requiring tab switches.

---

## Files to Modify

| File | Tasks |
|---|---|
| `Compass/Views/Today/VitalsGridView.swift` | 1 (add `sleepHistory`, wrap sleep card in `NavigationLink`) |
| `Compass/Views/Today/TodayView.swift` | 1 (compute `sleepHistory`, pass to grid), 2b (apply modifier, delete `connectionPill`) |
| `Compass/Components/ConnectionSyncStatusView.swift` | 2a (new file: view + view modifier) |
| `Compass/Views/Activity/ActivitiesListView.swift` | 2b (apply modifier) |
| `Compass/Views/Health/HealthView.swift` | 2b (apply modifier) |
| `Compass/Views/Courses/CoursesListView.swift` | 2b (apply modifier) |

---

## Known Limitations

- **Settings sheet visibility (Task 2b)**: The `SettingsView` is presented as a `.sheet` from Today's toolbar. Sheets do not inherit the parent's toolbar items, so the in-sheet "Watch Status" section in Settings (`SettingsView.swift:116`) remains the user's source of truth there. No change needed.
- **Failed-state dwell time (Task 2a)**: The plan specifies "show 'Sync failed' for ~5 s, then revert" but does not implement an auto-clear timer. The current `SyncCoordinator` already transitions `.failed` → `.idle` after a short window for course uploads (`SyncCoordinator.swift:673-675`); confirm the same happens for `sync(context:)` (line 435-437 — yes, transitions to `.idle` after error log). No timer in the view is needed; the source of truth handles the dwell.
- **Toolbar collisions on Activities (Task 2b)**: `ActivitiesListView` already uses sport-filter chips in a custom layout. The leading-edge toolbar item should not collide, but verify visually on iPhone SE (375 pt) — chips are in the body, not the toolbar.
- **TabView title behaviour (Task 2b)**: When `NavigationStack` pushes a detail (e.g. `ActivityDetailView`), the toolbar item travels with the navigation bar. That means the indicator stays visible inside detail screens too — which is the intended outcome and matches the work-item phrasing "visible from any screen".
