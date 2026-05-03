# WP-8 · `fitdump` CLI — Implementation Plan

A small command-line tool that runs the project's existing parsers over `.fit` files and prints the parsed structures. Lets us debug parsing regressions without launching the iOS app, and underpins the WP-9 parsing audit.

## Current State

| Area | Current |
|---|---|
| Parser entry points | `ActivityFITParser.parse(data:)`, `MonitoringFITParser(profile:).parse(data:)`, `SleepFITParser(profile:).parse(data:)`, `MetricsFITParser().parse(data:)`. All return value types defined in `CompassFIT` and `CompassData` (e.g. `MonitoringResults`, `SleepResult`, `[HRVResult]`, `Activity` + `[TrackPoint]`). |
| Raw FIT message access | `FitFile(data:).messages` returns `[FitMessage]`. `FitMessage` exposes `messageType` (Int) and `interpretedField(key:)` for typed lookup. There is no built-in "dump every field" helper. |
| Device-profile selection | `DeviceProfile.profile(for: UInt16)` in `CompassData`. The Instinct Solar 1G profile flips `usesSleepBlobMessage274 = true`. |
| Existing executables | None. The repo is one app target plus four library packages. |
| FIT file naming | Synced files in the app are named `{type}_{ISO-date}_{fileIndex}.fit` (see `FileSyncSession.saveFITFile`). `monitor`, `activity`, `sleep`, `metrics` substrings disambiguate type. |

---

## Implementation Order

1. **Task 1 — Add `fitdump` executable target** (SwiftPM wiring, no logic)
2. **Task 2 — Type detection + parser dispatch** (filename + `--type` override)
3. **Task 3 — Pretty-printers per result kind** (the actually-useful output)
4. **Task 4 — `--raw` mode using `RawFITRecordScanner`** (shared with the in-repo scanner)
5. **Task 5 — `--profile` flag** to exercise device-specific parsing paths

---

## Task 1 — Executable Target

**Risk: LOW** — pure packaging.

Create a new top-level package `Tools/fitdump/` so the tool ships outside the app bundle and can be built standalone with `swift run` from any developer machine.

### `Tools/fitdump/Package.swift`

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "fitdump",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../Packages/CompassFIT"),
        .package(path: "../../Packages/CompassData"),
        .package(path: "../../Packages/FitFileParser"),
    ],
    targets: [
        .executableTarget(
            name: "fitdump",
            dependencies: [
                .product(name: "CompassFIT", package: "CompassFIT"),
                .product(name: "CompassData", package: "CompassData"),
                .product(name: "FitFileParser", package: "FitFileParser"),
            ],
            path: "Sources"
        ),
    ]
)
```

Why a separate package and not a target inside `CompassFIT`? Two reasons:
- Keeps `CompassFIT`'s `Package.swift` iOS-only; the parsers compile for iOS today and we don't want to add `.macOS` to a library that doesn't need it.
- `swift run --package-path Tools/fitdump fitdump …` is the canonical workflow; a developer never builds the iOS app to use it.

### Build / run

```
swift run --package-path Tools/fitdump fitdump path/to/file.fit
swift run --package-path Tools/fitdump fitdump --type monitor file.fit
swift run --package-path Tools/fitdump fitdump --raw file.fit
swift run --package-path Tools/fitdump fitdump --profile instinct-solar-1g file.fit
```

**Acceptance criteria**
- `swift build --package-path Tools/fitdump` succeeds on macOS without touching the iOS app build.
- `swift run --package-path Tools/fitdump fitdump --help` prints the usage block.

---

## Task 2 — Type Detection + Parser Dispatch

**Risk: LOW** — mirrors the routing already in `SyncCoordinator.processFITFiles`.

### `Tools/fitdump/Sources/main.swift`

```swift
import Foundation
import CompassFIT
import CompassData

// MARK: - Argument parsing

struct Options {
    var path: URL
    var explicitType: FITKind?     // nil → infer from filename
    var raw: Bool = false
    var profile: DeviceProfile = .default
}

enum FITKind: String, CaseIterable {
    case activity, monitor, sleep, metrics

    /// Mirrors the substring matching in `SyncCoordinator.processFITFiles`.
    static func infer(from filename: String) -> FITKind? {
        let lower = filename.lowercased()
        if lower.contains("activity") || lower.contains("act") { return .activity }
        if lower.contains("monitor")  || lower.contains("mon") { return .monitor }
        if lower.contains("sleep")    || lower.contains("slp") { return .sleep }
        if lower.contains("metric")   || lower.contains("met") { return .metrics }
        return nil
    }
}
```

Argument parsing: a hand-rolled loop is enough — no third-party dependency. Support `--type`, `--raw`, `--profile`, `--help`, plus a single positional path.

### Dispatch

```swift
let data = try Data(contentsOf: opts.path)
let kind = opts.explicitType ?? FITKind.infer(from: opts.path.lastPathComponent)
guard let kind else {
    fputs("Cannot infer type from filename. Pass --type activity|monitor|sleep|metrics.\n", stderr)
    exit(2)
}

if opts.raw {
    try await dumpRaw(data: data)
    return
}

switch kind {
case .activity: try await dumpActivity(data, profile: opts.profile)
case .monitor:  try await dumpMonitoring(data, profile: opts.profile)
case .sleep:    try await dumpSleep(data, profile: opts.profile)
case .metrics:  try await dumpMetrics(data)
}
```

**Acceptance criteria**
- A monitor file is auto-routed to `MonitoringFITParser`; `--type sleep` overrides the inference.
- Unknown filenames exit non-zero with a clear message.

---

## Task 3 — Pretty-Printers per Result Kind

**Risk: LOW** — formatting only.

The output should be terse but show the things we'd actually want when debugging. Default to a header summary + first/last few samples per series; no JSON unless we add `--json` later.

### Activity

```
== Activity ==
sport: cycling   start: 2026-04-30 07:12:14 UTC   duration: 01:42:11
distance: 38.40 km  ascent: 412 m  descent: 410 m  calories: 1284
avg/max HR: 142 / 178 bpm
track points: 6132   gps: 6094   altitude: 6132   speed: 6132   cadence: 0
first point: 2026-04-30 07:12:14   47.3712, 8.5421   alt 412.0   hr 102   spd 5.4 m/s
last  point: 2026-04-30 08:54:25   47.3702, 8.5419   alt 414.0   hr 132   spd 0.0 m/s
```

Helper `summarize(_ trackPoints: [TrackPoint])` counts non-nil per field (this is what surfaced the "speed/altitude missing because of `enhanced_*`" bug).

### Monitoring

```
== Monitoring ==
heart rate samples : 1428   range 48–164 bpm   span 2026-04-30 00:00 → 23:58
stress samples     : 96     range  4–82
body battery       : 96     range 12–98
respiration        : 144    range  9.2–18.4 bpm
SpO2               : 24     range 92–99 %
intervals          : 96     steps total: 8421   intensity-min total: 64
first interval: 2026-04-30 00:00   steps=12  type=2  intensityMin=0   kcal=2.4
last  interval: 2026-04-30 23:45   steps=0   type=0  intensityMin=0   kcal=1.1
```

### Sleep

```
== Sleep ==
session: 2026-04-30 23:14 → 2026-05-01 06:42  (07:28)
score: 78  recovery: 84  qualifier: good
stages (5):
  23:14–23:48   light  (00:34)
  23:48–01:12   deep   (01:24)
  01:12–02:48   light  (01:36)
  02:48–04:24   rem    (01:36)
  04:24–06:42   light  (02:18)
```

If no session was produced, print `== Sleep ==\n(no session emitted — N raw stages parsed)` so we can tell the difference between "watch had nothing to send" and "parser returned nil".

### Metrics

```
== HRV ==
samples: 32   range 18–96 ms   span 2026-04-30 23:14 → 06:42
first: 2026-04-30 23:18   rmssd=42.0
last : 2026-05-01 06:38   rmssd=58.0
```

**Acceptance criteria**
- Each kind prints a header, totals, and a head/tail line for each series.
- Counts of non-nil per TrackPoint field are visible in activity output.

---

## Task 4 — `--raw` Mode

**Risk: LOW** — wraps `RawFITRecordScanner` (already in `Packages/CompassFIT/Sources/CompassFIT/Parsers/`).

The scanner already iterates every `FitMessage` and yields field-level info; reuse it instead of writing a second walker. Output one block per message:

```
[#1284] mesg=20 record
  timestamp        = 2026-04-30 07:12:14 UTC
  position_lat     = 47.3712
  position_long    = 8.5421
  enhanced_speed   = 5.4
  altitude         = (nil)
  enhanced_altitude= 412.0
  heart_rate       = 102
```

Sorting fields alphabetically inside each block makes diffs readable. `--raw --grep heart_rate` (a thin extra filter on key name) is a useful optional refinement; defer until needed.

**Acceptance criteria**
- `fitdump --raw monitor_*.fit | grep enhanced_` lists every enhanced-field row across the file.
- Nil-valued fields are printed as `(nil)` so we can tell the difference between "key absent" and "key present, value nil".

---

## Task 5 — `--profile` Flag

**Risk: LOW** — one-liner translation table.

```swift
extension DeviceProfile {
    static func named(_ name: String) -> DeviceProfile? {
        switch name.lowercased() {
        case "default":             return .default
        case "instinct-solar-1g":   return .instinctSolar1G
        default:                    return nil
        }
    }
}
```

Without this, sleep msg-274 blob decoding never runs in the CLI for Instinct files. Default to `.default`; the developer opts into a profile when they know the source watch.

**Acceptance criteria**
- `--profile instinct-solar-1g sleep_*.fit` produces stages from the 20-byte blob; `--profile default` on the same file produces an empty session and prints the "no session emitted" diagnostic.

---

## Files to Add

| File | Purpose |
|---|---|
| `Tools/fitdump/Package.swift` | Standalone executable package |
| `Tools/fitdump/Sources/main.swift` | Argument parsing + top-level dispatch |
| `Tools/fitdump/Sources/Printers.swift` | Per-kind pretty-printers (Task 3) |
| `Tools/fitdump/Sources/RawDump.swift` | `--raw` walker (Task 4) |

No changes inside `Packages/`; the parsers must remain unchanged so the CLI proves what the app sees.

---

## Known Limitations

- **macOS-only**. The tool isn't shipped to users; this is fine.
- **Not wired into CI**. Worth adding a smoke `swift build --package-path Tools/fitdump` step later, but out of scope for WP-8.
- **No JSON output**. Easy to add (`--json`) when something downstream wants it; defer until there's a concrete consumer.
- **Field-name churn**. `--raw` output mirrors the FIT profile's field names; if the profile is regenerated, the keys may rename. Acceptable — that's a faithful view of the parser input.
