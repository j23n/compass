# WP-6 · Health & Courses Views — Implementation Plan

Polish and correctness across the Health detail screen and the Courses detail screen.

## Current State

| Area | Current |
|---|---|
| Health card popout | `RuleMark(x: .value(_, b.date, unit: xUnit))` with `.annotation(position: .top, overflow: .fit)` on both `InteractiveTrendCard` and `HealthDetailView` |
| Health detail Statistics | 3-column `Grid` row with Average / Min / Max only; no mean/stddev/count, no table alignment |
| Courses "on watch" check | `SyncCoordinator.checkCourseOnWatch` calls `deviceManager.listCourseFiles()` → `FileSyncSession.listFiles(ofType: .course)`. The session downloads `fileIndex=0` (root directory) and filters for `FileType.course = 6`. Per `docs/garmin/gfdi/file-sync-download.md:216`, course is **upload-only direction** — root directory does not contain uploaded course files, so the filter always yields an empty array and the check returns `false` (not‑found) for every uploaded course. |
| Courses stats grid | `LazyVGrid` with 2 flexible columns, `spacing: 12`, "Course Stats" heading |
| Courses sport picker | Inline `Picker("Sport", …)` in `sportSection` directly on the detail view; commits via `onChange(of: selectedSport)` |
| Courses rename | Inline `.alert("Rename Course", …)` triggered by toolbar pencil button |

---

## Implementation Order

1. **Task 1 — Popout horizontal anchoring fix** (smallest, highest user-visible value)
2. **Task 2 — Statistics: mean + std dev + table layout** (additive, single view)
3. **Task 4 — Courses: 3-column stat grid** (matches WP-5 pattern, no risk)
4. **Task 5 — Course Edit sheet (sport + rename)** (re-organises detail view; do before Task 3 because Task 3 may delete the surrounding code)
5. **Task 3 — Courses "on watch" check: investigation + decision** (sequenced last because the answer may be "remove the feature")

---

## Task 1 — Popout Horizontal Anchoring Fix

**Risk: LOW** — chart-mark argument change only; no data or state changes.

### Root cause

Both `barChart` bodies (`InteractiveTrendCard.swift:233` and `HealthDetailView.swift:331`) use:

```swift
RuleMark(x: .value("Selected", b.date, unit: xUnit))
```

Swift Charts positions a value with a `unit:` parameter at the **leading edge** of the unit interval. The bar itself spans the whole interval and appears centred under the bucket, so the rule and its `position: .top` annotation are anchored to the *left edge* of the bar — which is what the user is seeing as "popout to the left of the bar".

The scatter chart (`scatterChart`) uses an exact `point.date`, so it is unaffected.

### Fix

Anchor the rule (and therefore the annotation) at the centre of the bucket. Compute a `bucketCenterDate(_:)` helper from `xUnit` and pass that to the `RuleMark` without the `unit:` parameter:

```swift
private func bucketCenterDate(_ date: Date) -> Date {
    let cal = Calendar.current
    switch xUnit {
    case .hour:  return cal.date(byAdding: .minute, value: 30, to: date) ?? date
    case .day:   return cal.date(byAdding: .hour,   value: 12, to: date) ?? date
    case .month:
        // mid-month → add half the actual length of this month
        let range = cal.range(of: .day, in: .month, for: date) ?? 1..<31
        let half  = (range.count) / 2
        return cal.date(byAdding: .day, value: half, to: date) ?? date
    default: return date
    }
}
```

```swift
if let b = selectedBucket {
    RuleMark(x: .value("Selected", bucketCenterDate(b.date)))
        .foregroundStyle(Color.secondary.opacity(0.4))
        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
        .annotation(position: .top, spacing: 4,
                    overflowResolution: .init(x: .fit, y: .disabled)) {
            calloutView(value: barCalloutValue(b), date: b.date)
        }
}
```

Apply the identical change in **both** `InteractiveTrendCard.swift` (`:233-240`) and `HealthDetailView.swift` (`:330-337`).

The drag-to-select handler (`selectedBucket = buckets.min(by: …)` against the rule date) is unaffected because the comparison still uses the original `b.date` from the bucket source.

**Acceptance criteria**
- Tapping a bar in any of Week / Month / Year mode positions the popout centred above the tapped bar.
- Tapping the rightmost bar still flips inside via `overflowResolution: .fit` (no clipping).
- Day-mode scatter callout positioning is unchanged.

---

## Task 2 — Statistics: Mean, Std Dev, Table Layout

**Risk: LOW** — pure presentation change scoped to `HealthDetailView.statisticsSection`.

### `HealthDetailView.swift` — add std-dev and count helpers

```swift
private var sourceValues: [Double] {
    selectedRange == .day ? filteredData.map(\.value) : buckets.map(\.display)
}

private var stdDevDisplay: Double {
    let v = sourceValues
    guard v.count > 1 else { return 0 }
    let mean = v.reduce(0, +) / Double(v.count)
    let variance = v.reduce(0) { $0 + pow($1 - mean, 2) } / Double(v.count - 1)
    return sqrt(variance)
}

private var sampleCount: Int { sourceValues.count }
```

(Sample stddev — `n‑1` denominator. Matches the convention used by Health/Fit apps and by `.mean()`/`.standardDeviation()` semantics in HealthKit.)

### Replace the `statisticsSection` body

Replace the 3-column `Grid { GridRow { … } }` with a 2-column label/value table:

```swift
@ViewBuilder
private var statisticsSection: some View {
    let hasData = selectedRange == .day ? !filteredData.isEmpty : !buckets.isEmpty
    if hasData {
        VStack(alignment: .leading, spacing: 12) {
            Text("Statistics").font(.headline)
            Grid(alignment: .leadingFirstTextBaseline,
                 horizontalSpacing: 24,
                 verticalSpacing: 10) {
                statRow("Mean",     valueFormatter(averageDisplay))
                Divider()
                statRow("Std Dev",  valueFormatter(stdDevDisplay))
                Divider()
                statRow("Min",      valueFormatter(minDisplay))
                Divider()
                statRow("Max",      valueFormatter(maxDisplay))
                Divider()
                statRow("Count",    String(sampleCount))
            }
        }
        .padding()
        .background(card)
    }
}

@ViewBuilder
private func statRow(_ label: String, _ value: String) -> some View {
    GridRow {
        Text(label)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.leading)
        Text(value)
            .font(.subheadline).fontWeight(.semibold)
            .monospacedDigit()
            .gridColumnAlignment(.trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private var card: some View {
    RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(.background)
        .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 2)
}
```

(Drop the redundant `.overlay { strokeBorder }` if the new card factor is reused; otherwise leave it.)

### Notes

- "Average" → "Mean" so the heading is consistent with statistical vocabulary.
- `.monospacedDigit()` keeps the right column visually aligned across rows for variable-width numerals.
- `Divider()` between rows gives the table look the work item asks for; if the visual gets too busy, switch to `Divider().opacity(0.4)` or drop the dividers entirely and rely on row spacing.

**Acceptance criteria**
- Statistics card shows Mean, Std Dev, Min, Max, Count rows in a single 2-column table.
- All values are right-aligned and use monospaced digits.
- Std dev computes via sample formula: for `[1, 2, 3]`, value renders as `1` (via `valueFormatter`), not `0`.
- Day range with a single sample shows Std Dev "0" / "—" without a divide-by-zero.

---

## Task 4 — Courses: 3-Column Stat Grid

**Risk: LOW** — `LazyVGrid` columns count change.

### `CourseDetailView.swift` — `StatsGrid`

```swift
// was:
LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) { … }

// becomes:
LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 10) { … }
```

Rename the heading "Course Stats" → "Stats" so it matches WP-5's section title conventions. The 5 existing cells (Distance, Est. Time, Ascent?, Descent?, Waypoints) lay out cleanly in 3 columns (full row of three + a row of up-to-two; any conditional ascent/descent stays intact).

`StatCell` already received the WP-5 compaction (`.headline` value font, 8 pt vertical padding); no further change required.

**Acceptance criteria**
- Courses detail stats grid renders as 3 columns matching the activity detail view.
- A course with both ascent and descent shows all 5 cells without truncation on iPhone 14.

---

## Task 5 — Course Edit Sheet (Sport + Rename)

**Risk: LOW-MEDIUM** — view restructuring; no model changes; replaces existing alert + inline picker.

### Goal

Move sport selection and renaming out of the detail view body and into a single dedicated edit screen, opened from the toolbar pencil. This:

- Removes the inline `sportSection` HStack from the scrollable body.
- Replaces the alert-based rename with a proper editable form.
- Gives one place to extend later (e.g. estimated-duration overrides) without further cluttering the detail view.

### New file: `Compass/Views/Courses/CourseEditView.swift`

```swift
import SwiftUI
import CompassData

struct CourseEditView: View {
    @Bindable var course: Course
    @Environment(\.dismiss) private var dismiss

    @State private var draftName: String
    @State private var draftSport: Sport

    init(course: Course) {
        self.course = course
        _draftName  = State(initialValue: course.name)
        _draftSport = State(initialValue: course.sport)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Course name", text: $draftName)
                        .textInputAutocapitalization(.words)
                }
                Section("Sport") {
                    Picker("Sport", selection: $draftSport) {
                        ForEach(Sport.allCases, id: \.self) { sport in
                            Label(sport.displayName, systemImage: sport.systemImage)
                                .tag(sport)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            .navigationTitle("Edit Course")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(saveDisabled)
                }
            }
        }
    }

    private var saveDisabled: Bool {
        draftName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() {
        let trimmed = draftName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { course.name = trimmed }
        course.sport = draftSport
        dismiss()
    }
}
```

### `CourseDetailView.swift` — refactor

- Delete `selectedSport`, `isRenaming`, `draftName` state.
- Delete `sportSection` and the inline `.alert("Rename Course", …)`.
- Add `@State private var isEditing = false`.
- Replace toolbar action body with:

```swift
ToolbarItem(placement: .primaryAction) {
    Button { isEditing = true } label: { Image(systemName: "pencil") }
}
```

- Add modifier:

```swift
.sheet(isPresented: $isEditing) {
    CourseEditView(course: course)
}
```

- Remove `sportSection` from the body's `VStack`. The edit pencil now owns sport selection. Distance / ascent / descent / etc. continue to render through `StatsGrid`.

### Inline-picker behaviour parity

The previous picker committed `course.sport = new` on every change. The new sheet commits both fields atomically on Save. Cancel discards changes. This is the standard SwiftUI editing pattern; no migration concerns since the model is unchanged.

**Acceptance criteria**
- Toolbar pencil opens a sheet with editable name + sport.
- Save commits both fields and dismisses; Cancel leaves the course untouched.
- Detail view no longer contains the inline sport row.
- Save button is disabled when name is empty or whitespace-only.

---

## Task 3 — Courses "On Watch" Check: Investigation + Decision

**Risk: MEDIUM** — investigation-first; the implementation depends on what the protocol actually exposes.

### Why this is sequenced last

The current code path is fundamentally a query of the watch's *root directory*. Per `docs/garmin/gfdi/file-sync-download.md:216`, `course (subType=6)` is documented as "upload-only direction" — i.e. the watch lists files it has *produced*, not files we have *uploaded* to it. If that documentation is correct, the entire `checkCourseOnWatch` code path (`SyncCoordinator.swift:715-727`, `GarminDeviceManager.listCourseFiles`, `FileSyncSession.listFiles(ofType:)`) is dead code and the UI's tri-state `watchPresence` view is misleading.

### Step 1 — Confirm directly from a real watch

Run the existing presence check against an Instinct that has a known-uploaded course and capture the raw directory listing. The session already logs every directory entry (`FileSyncSession.swift:75 logDirectoryEntries`). On the test device:

1. Upload a course → success → confirm `course.uploadedToWatch == true` and `watchFITSize` set.
2. Trigger `checkCourseOnWatch` (open the detail view; logs land in `LogsView` under `sync` category).
3. Inspect logged entries: do **any** have `dataType == 128 && subType == 6`? Do any have a previously-unmapped `subType` whose `fileSize` matches the uploaded FIT?

Record findings in `docs/garmin/gfdi/file-sync-download.md` under "FileType table" (extend with any new sub-type seen).

### Step 2 — Decide based on findings

| Finding | Action |
|---|---|
| Course rows DO appear under `subType=6` | Leave `FileType.course` filter as-is. The bug is elsewhere — most likely the Instinct returns `fileSize` for the on-watch file that does **not** match the byte length of what we uploaded (Garmin re-stamps headers on receive). Change `checkCourseOnWatch` to match by `(fileNumber, dateProximity)` instead of size, *or* drop the size match and rely on "any course is present" if we only ever upload one course at a time. |
| Course rows appear under a different sub-type | Add the new sub-type to `FileType` (`Packages/CompassBLE/Sources/CompassBLE/Sync/FileMetadata.swift`) and update `listFiles(ofType:)` to accept either. Cross-check with `docs/garmin/references/gadgetbridge-pairing.md` for the canonical Gadgetbridge name. |
| No course rows appear in any form | The protocol does not expose uploaded courses — the feature cannot work on this firmware. Implement Step 3 (tear-down). |

### Step 3 — If the protocol does not expose uploaded courses

Remove the broken check rather than leave a misleading orange "Not found on watch" badge:

- `SyncCoordinator.checkCourseOnWatch(course:)` — delete.
- `DeviceManagerProtocol.listCourseFiles()`, `GarminDeviceManager.listCourseFiles()`, `MockGarminDevice.listCourseFiles()`, `FileSyncSession.listFiles(ofType:)` — delete (they have no other caller).
- `Course.watchFITSize` — keep (still useful as a record of the last upload; harmless if unused).
- `CourseDetailView`:
  - Delete `watchPresence` state and the `.task { … }`.
  - Delete `watchStatusRow(isConnected:)`.
  - In `uploadSection`, replace the conditional `watchStatusRow` with a single static row when `course.uploadedToWatch == true`:

    ```swift
    if course.uploadedToWatch, let date = course.lastUploadDate {
        HStack(spacing: 8) {
            Image(systemName: "applewatch").foregroundStyle(.secondary)
            Text("Last uploaded \(date.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
    ```

- `CourseRowView` `.uploadedToWatch` badge stays — it now means "ever uploaded by us", which is the only honest signal we can give.
- Update `docs/garmin/gfdi/file-sync-download.md` to record explicitly: "Compass cannot verify presence of uploaded courses on the watch; the root directory does not list them."

### Step 4 — If the size-match is the bug (likeliest non-tear-down outcome)

If course rows do appear in the directory but `fileSize` does not match what we uploaded, change the matcher:

```swift
// SyncCoordinator.checkCourseOnWatch
let files = try await deviceManager.listCourseFiles()
let found: Bool
if let lastUpload = course.lastUploadDate {
    // Match by recency: any course uploaded within ±5 minutes of our last attempt
    found = files.contains {
        abs($0.date.timeIntervalSince(lastUpload)) < 300
    }
} else if let fitSize = course.watchFITSize {
    found = files.contains { Int($0.size) == fitSize }
} else {
    found = !files.isEmpty
}
```

(The size-match remains as a fallback for already-installed courses where we never recorded `lastUploadDate`.)

**Acceptance criteria**
- Either: presence check returns `true` for a known-uploaded course on a real Instinct; the green "On your watch" pill renders. Logs show the matched directory entry.
- Or: the presence check and its tri-state UI are removed; uploaded courses show "Last uploaded {date}" only; no orange "Not found" claim ever renders. Documentation explicitly notes the limitation.

---

## Files to Modify

| File | Tasks |
|---|---|
| `Compass/Views/Health/InteractiveTrendCard.swift` | 1 |
| `Compass/Views/Health/HealthDetailView.swift` | 1, 2 |
| `Compass/Views/Courses/CourseDetailView.swift` | 4, 5, (3 if tear-down) |
| `Compass/Views/Courses/CourseEditView.swift` | 5 (new file) |
| `Compass/App/SyncCoordinator.swift` | 3 (modify or delete `checkCourseOnWatch`) |
| `Packages/CompassBLE/Sources/CompassBLE/Public/DeviceManagerProtocol.swift` | 3 (delete `listCourseFiles` if tear-down) |
| `Packages/CompassBLE/Sources/CompassBLE/Public/GarminDeviceManager.swift` | 3 (delete `listCourseFiles` if tear-down) |
| `Packages/CompassBLE/Sources/CompassBLE/Public/MockGarminDevice.swift` | 3 (delete `listCourseFiles` if tear-down) |
| `Packages/CompassBLE/Sources/CompassBLE/Sync/FileSyncSession.swift` | 3 (delete `listFiles(ofType:)` if tear-down) |
| `Packages/CompassBLE/Sources/CompassBLE/Sync/FileMetadata.swift` | 3 (extend `FileType` if a new sub-type is found) |
| `docs/garmin/gfdi/file-sync-download.md` | 3 (document either the new sub-type or the limitation) |

---

## Known Limitations

- **Bucket centre offset (Task 1)**: The `bucketCenterDate` heuristic uses calendar arithmetic and assumes hour/day/month buckets. If the Year mode ever adopts a non-month unit (week, quarter), extend the switch.
- **Sample stddev (Task 2)**: Defined only for `n > 1`; the helper returns `0` for single-sample windows. The UI renders `valueFormatter(0)` (e.g. "0 bpm") which is technically misleading. Consider rendering "—" when `sampleCount < 2`.
- **`@Bindable course` in edit sheet (Task 5)**: SwiftData `@Model` types support `@Bindable`. We deliberately do NOT bind text fields directly to the model so Cancel can discard; instead we hold drafts in `@State` and copy on Save.
- **Course presence check (Task 3)**: The investigation may invalidate the `watchFITSize` field's reason for existing. Leave the field on the model — removing a SwiftData property requires a schema migration, and the field is harmless if unused.
