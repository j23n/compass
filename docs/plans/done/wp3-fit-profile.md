# WP-3 · FIT Profile & Parser Refactor — Implementation Plan

## Background

The current FIT parsing stack has two independent problems that compound each other:

1. **Custom decoder (`FITDecoder.swift`) invented from scratch.** There is an actively-maintained, MIT-licensed Swift package (`roznet/FitFileParser`) that wraps the official Garmin FIT C SDK and handles the binary decode layer correctly, including compressed timestamps, developer fields, and multi-file edge cases. We should not maintain a parallel implementation.

2. **Fabricated overlay (`harry_overlay.json`).** The file was hand-written and contains multiple critical errors confirmed against the three authoritative sources (Gadgetbridge `NativeFITMessage.java`, HarryOnline additions spreadsheet, official `Profile.xlsx` shipped with roznet/FitFileParser). Several messages are misidentified and our parsers are silently reading the wrong data from the device.

The fix is a three-layer pipeline:

```
Authoritative sources                  Script                    Generated artefact
──────────────────────────────────────────────────────────────────────────────────
roznet Profile.xlsx   (official base)  ┐
Gadgetbridge                           ├─ augment_profile.py ──► Profile.aug.xlsx
  NativeFITMessage.java                ┘        │
HarryOnline                                     │ (flags conflicts for human review)
  Additions - Messages.csv                      │
  Additions - Types.csv                         ▼
                                       fitsdkparser.py ────────► rzfit_swift_map.swift
                                       (from roznet repo)        rzfit_swift_reverse_map.swift
                                                                  rzfit_objc_map.m / .h
```

The Swift parsers are then updated to use the generated message-name enum instead of hardcoded integers.

---

## Known Errors in the Current Overlay

The following are confirmed wrong against ≥2 authoritative sources. **Do not trust `harry_overlay.json`** — treat every entry as suspect until verified.

| Msg # | Our name | Authoritative name | What is wrong |
|---|---|---|---|
| 140 | `monitoring_hr` | `physiological_metrics` | Completely different message. Post-activity summary (VO2max, training effect, LTHR). Field 1 = `new_hr_max`, not heart rate samples. Monitoring parser dispatches on 140 expecting HR data and gets activity metrics instead. |
| 233 | `monitoring_v2` | unknown (`mesg_233`) | All field definitions fabricated. Only confirmed field is 2 = opaque bytes. |
| 273 | `sleep_data_info` | `sleep_data_info` | Name correct. Field 0 = quality category (enum 0–3), field 1 = `sample_length` (60 = 60 s) per Gadgetbridge/Harry, **not** sleep score. Field 2 = `local_timestamp`, not `start_time`. Sleep score location is unconfirmed. |
| 274 | `sleep_level` | `sleep_data_raw` | Gadgetbridge defines this as raw bytes, 20 bytes per sample. We parse field 0 as a sleep-level uint8. May be coincidentally correct for first byte on Instinct Solar 1G, but is not the authoritative interpretation. |
| 275 | `sleep_stage` | `sleep_stage` | Name correct. Gadgetbridge has no `duration` field (field 1). We invented it. |
| 276 | `sleep_assessment` | unknown | No entry in Gadgetbridge or Harry. Fields were fabricated. |
| 346 | `body_battery` | `sleep_stats` | **Critical.** Message 346 = sleep quality sub-scores (Gadgetbridge). Fields 0–11 are sleep score components. We dispatch on it expecting body-battery level/charged/drained. Body-battery history lives in HSA message 314 (`hsa_body_battery_data`), which we already have correctly. |
| 382 | `sleep_restless_moments` | `sleep_restless_moments` | Name correct. Field 0 is `unknown_0` (uint32) per Gadgetbridge, not `duration`. We invented field 0. |

Consequences to fix before shipping any sleep or monitoring data:
- The `bodyBatteryMessageNum = 346` dispatch in `MonitoringFITParser` is reading sleep stats and treating the sub-scores as body-battery level/charged/drained.
- The `monitoringHRMessageNum = 140` dispatch is reading physiological-metrics records and treating `new_hr_max` as a per-sample heart-rate reading.
- The sleep score field in message 273 is unconfirmed — we may be reporting `sample_length` (60) as the sleep score for every night.

---

## Implementation Order

1. **Task 1 — Add `roznet/FitFileParser` as SPM dependency** (no behaviour change; parallel to existing decoder)
2. **Task 2 — Write `augment_profile.py`** (script that builds augmented xlsx from all sources)
3. **Task 3 — Run pipeline, review conflicts, commit generated Swift** (regenerate with fitsdkparser.py)
4. **Task 4 — Replace `FITDecoder` with `FitFileParser` in CompassFIT** (swap decode layer)
5. **Task 5 — Eliminate hardcoded message numbers from all parsers** (use generated name enum)
6. **Task 6 — Fix known errors; verify contested fields against live device data**

Tasks 1 and 2 are independent and can proceed in parallel.

---

## Task 1 — Add `roznet/FitFileParser` as SPM dependency

**Risk: LOW** — additive only; existing code untouched.

### What to do

Add the package to `Packages/CompassFIT/Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/roznet/FitFileParser", from: "1.0.0"),
    .package(path: "../CompassData"),
],
targets: [
    .target(
        name: "CompassFIT",
        dependencies: [
            .product(name: "FitFileParser", package: "FitFileParser"),
            "CompassData",
        ]
    )
]
```

Verify the package resolves and the project builds before proceeding.

### Acceptance criteria
- `swift build` succeeds in `Packages/CompassFIT`
- No API changes to CompassFIT's public surface

---

## Task 2 — Write `augment_profile.py`

**Risk: LOW** — pure Python, no Swift changes.

### Overview

The script lives at `scripts/augment_profile.py`. It:

1. Starts from the **official `Profile.xlsx`** vendored in `roznet/FitFileParser/python/` (fetched via the roznet SPM checkout or copied to `data/fit-sdk/Profile.xlsx`).
2. Reads **Gadgetbridge `NativeFITMessage.java`** from the Codeberg API (or a locally-cached copy at `data/gadgetbridge/NativeFITMessage.java`).
3. Reads **Harry's CSVs** from `data/Harry/Additions - Messages.csv` and `data/Harry/Additions - Types.csv`.
4. For each message/field, determines the **winning definition** using priority:
   - Official SDK (in existing `Profile.xlsx`) → highest trust, never overwritten
   - Gadgetbridge → second priority (reverse-engineered from Garmin firmware)
   - Harry → third priority (community-documented, additions only)
5. **Flags every conflict** — where Gadgetbridge and Harry disagree, or where a message exists in one source but not the other — into `data/conflicts.md`. The user resolves these manually before running `fitsdkparser.py`.
6. Appends the merged rows to the Messages and Types sheets of the output xlsx.
7. Writes `data/fit-sdk/Profile.aug.xlsx`.

### xlsx sheet format

The Messages sheet uses exactly 16 columns matching `fitsdkparser.py`'s `MSG_COL_*` constants:

```
Message Name | Field Def # | Field Name | Field Type | Array | Components |
Scale | Offset | Units | Bits | Accumulate | Ref Field Name | Ref Field Value |
Comment | Products | Example
```

Harry's CSV already uses this layout (with two extra trailing columns that the script ignores).

The Types sheet uses 5 columns:

```
Type Name | Base Type | Value Name | Value | Comment
```

### Conflict detection

A conflict is logged when:
- Gadgetbridge and Harry both define the same (message, field\_def) but with different field name, type, or units.
- A message exists in one source with a global message number but not in the other.
- A message number exists in the official Profile.xlsx under a different name than Gadgetbridge/Harry use.

Output format in `data/conflicts.md`:

```markdown
## Message 273 — sleep_data_info

| Source | Field 1 name | Field 1 type |
|---|---|---|
| Gadgetbridge | sample_length | uint16 |
| Harry | sample_length | uint16 |
| Our parser (live observation, Instinct Solar 1G) | sleep_score | uint8 |

**Decision needed:** Does field 1 hold the numeric sleep score (0–100) or sample interval (60 s)?
Verify against a raw FIT file dump before choosing.
```

### Running the script

```bash
uv run python scripts/augment_profile.py \
  --base    data/fit-sdk/Profile.xlsx \
  --gadget  data/gadgetbridge/NativeFITMessage.java \
  --harry-messages  "data/Harry/Additions - Messages.csv" \
  --harry-types     "data/Harry/Additions - Types.csv" \
  --out     data/fit-sdk/Profile.aug.xlsx \
  --conflicts data/conflicts.md
```

After reviewing `conflicts.md` and resolving each dispute by editing `Profile.aug.xlsx` directly, run `fitsdkparser.py`:

```bash
cd <fitfileparser-checkout>/python
uv run python fitsdkparser.py generate Profile.aug.xlsx \
  -o ../Sources/FitFileParserObjc \
  -s ../Sources/FitFileParser
```

### Acceptance criteria
- Script runs to completion with no unhandled exceptions
- `Profile.aug.xlsx` contains all rows from the official base plus Gadgetbridge/Harry additions
- `data/conflicts.md` contains a human-readable entry for every detected discrepancy
- Messages already in the official Profile.xlsx are not overwritten

---

## Task 3 — Run pipeline, review conflicts, commit generated Swift

**Risk: MEDIUM** — requires human judgment on conflicts.

### What to do

1. Copy `Profile.xlsx` from the resolved roznet SPM checkout into `data/fit-sdk/`.
2. Fetch `NativeFITMessage.java` from Codeberg, save to `data/gadgetbridge/NativeFITMessage.java`.
3. Run `augment_profile.py` (see Task 2).
4. Open `data/conflicts.md`. For each conflict:
   - If the live-device observation is available (FIT file in `data/GARMIN/`), inspect the raw field values to determine which source is correct.
   - Otherwise, prefer Gadgetbridge (it is derived from actual Garmin firmware disassembly) over Harry (community-documented).
5. Edit `Profile.aug.xlsx` to reflect resolved decisions.
6. Run `fitsdkparser.py` to regenerate Swift files.
7. Commit `Profile.aug.xlsx`, `data/conflicts.md`, `data/gadgetbridge/NativeFITMessage.java`, and the generated Swift files.

### Acceptance criteria
- `data/conflicts.md` has a **Decision** line for every conflict
- `fitsdkparser.py` generates clean Swift with no warnings
- `swift build` succeeds after generated files are in place

---

## Task 4 — Replace `FITDecoder` with `FitFileParser` in CompassFIT

**Risk: MEDIUM** — changes the binary decode path; thorough testing against `data/GARMIN/` sample files required.

### Overview

`FitFileParser` exposes two parse modes:
- `.fast` — typed structs for messages in the official profile
- `.generic` — `[String: FitFieldValue]` dictionaries for all messages including unknowns

After augmenting Profile.xlsx and regenerating, most proprietary messages we care about will be in the typed/fast path. Any remaining unknowns use the generic path.

### Fix: swap decode layer

Each parser currently does:
```swift
let decoder = FITDecoder()
let fitFile = try decoder.decode(data: data)
for message in fitFile.messages { ... }
```

Replace with:
```swift
let fitFile = FitFile(data: data)
try fitFile.parse()
for message in fitFile.messages { ... }
```

The `FitMessage` type from FitFileParser exposes:
- `message.messageType` — the generated `FitMessageType` enum (e.g., `.sleep_data_info`)
- `message[field]` — field access by name
- `message.interpretedFields()` — full dictionary

### What to keep

`FITDecoder.swift`, `OverlayModels.swift`, `FieldNameOverlay.swift`, and `HarryOverlayNotes.swift` can all be deleted once this task is complete. The overlay concept is replaced by the generated Swift code from `fitsdkparser.py`.

### Acceptance criteria
- All existing unit tests (`FITDecoderTests`, `OverlayTests`) pass or are updated
- Parse the sample files in `data/GARMIN/` (Monitor, Sleep, Activity, Device) and confirm output matches pre-refactor output
- `FITDecoder.swift` removed from the target

---

## Task 5 — Eliminate hardcoded message numbers from all parsers

**Risk: LOW** — mechanical change; no logic changes.

### Overview

All four parsers currently define constants like:

```swift
private static let sleepDataInfoMessageNum: UInt16 = 273
private static let bodyBatteryMessageNum: UInt16 = 346   // ← WRONG
```

After Task 4, the dispatch switches to the generated `FitMessageType` enum:

```swift
switch message.messageType {
case .sleep_data_info:
    parseSleepDataInfo(message)
case .sleep_stats:           // was: 346, misidentified as body_battery
    parseSleepStats(message)
...
}
```

Field access changes from:

```swift
let score = message.fields[1]?.uint8Value     // magic number
```

to:

```swift
let score = message.numberForKey("sleep_score")   // generated name
```

### Files to update

| File | Change |
|---|---|
| `MonitoringFITParser.swift` | Replace all `UInt16` message-number constants; rewrite dispatch switch |
| `SleepFITParser.swift` | Same |
| `MetricsFITParser.swift` | Same |
| `ActivityFITParser.swift` | Same |

### Acceptance criteria
- No `UInt16 = \d+` message-number constants remain in any parser
- `swift build` with `-warnings-as-errors` succeeds

---

## Task 6 — Fix known errors; verify contested fields against live data

**Risk: HIGH** — may break currently-working (but accidentally correct) behaviour.

### Confirmed fixes

**`MonitoringFITParser.swift` — message 140**

Remove the `monitoringHRMessageNum = 140` dispatch entirely. Message 140 (`physiological_metrics`) is a post-activity record, not a monitoring-file message. If it appears in a monitoring file it carries no useful HR data. The HSA path (messages 306–314) is the correct source for intraday HR history.

**`MonitoringFITParser.swift` — message 346**

Remove the `bodyBatteryMessageNum = 346` dispatch. Message 346 is `sleep_stats` (sleep quality sub-scores). Actual body battery history is in `hsa_body_battery_data` (314), which is already parsed correctly via the HSA path. The `BodyBatterySample` type and its call-sites remain; they should be populated from message 314.

**`SleepFITParser.swift` — message 276**

The current `sleep_assessment` dispatch (276) field-dumps to the log. Message 346 (`sleep_stats`) is the correct source for sleep quality sub-scores. Redirect to 346.

### Contested fields requiring live-data verification

These cannot be resolved from source analysis alone. Use `data/GARMIN/Sleep/S4UA2600.FIT` and `data/GARMIN/Monitor/M4UA2600.FIT` as test inputs, print raw field values, and compare against Gadgetbridge source.

| Message | Field | Conflict |
|---|---|---|
| 273 `sleep_data_info` | field 1 | Gadgetbridge/Harry: `sample_length` (uint16, typically 60). Our parser: `sleep_score` (uint8, 0–100). Inspect the raw uint16 value in the live FIT file. A value of 60 = sample interval; a value of 0–100 = sleep score. |
| 274 `sleep_data_raw` | field 0 | Gadgetbridge: raw byte array (20 bytes per sample). Our parser: uint8 sleep level. The first byte of the raw data may coincidentally encode the level on Instinct Solar 1G firmware. Verify by reading multiple samples and checking byte-level structure. |
| 275 `sleep_stage` | field 1 | We invented a `duration` field. Gadgetbridge has none. Check whether field 1 actually appears in the live file. |

### Acceptance criteria
- `MonitoringFITParser` no longer dispatches on messages 140 or 346
- `SleepFITParser` dispatches on 346 for sleep stats, not 276
- The three contested fields are documented with a verified decision in `data/conflicts.md`
- Body battery samples continue to populate correctly from message 314
- Sleep sessions parse with correct start/end/score from live `S4UA2600.FIT`

---

## Files to Create / Modify / Delete

| File | Action | Task |
|---|---|---|
| `scripts/augment_profile.py` | **Create** | 2 |
| `data/fit-sdk/Profile.xlsx` | **Create** (copy from roznet) | 3 |
| `data/fit-sdk/Profile.aug.xlsx` | **Create** (generated) | 3 |
| `data/gadgetbridge/NativeFITMessage.java` | **Create** (fetched) | 3 |
| `data/conflicts.md` | **Create** (generated + reviewed) | 3 |
| `Packages/CompassFIT/Package.swift` | **Modify** (add FitFileParser dep) | 1 |
| `Packages/CompassFIT/Sources/CompassFIT/Parsers/MonitoringFITParser.swift` | **Modify** | 5, 6 |
| `Packages/CompassFIT/Sources/CompassFIT/Parsers/SleepFITParser.swift` | **Modify** | 5, 6 |
| `Packages/CompassFIT/Sources/CompassFIT/Parsers/MetricsFITParser.swift` | **Modify** | 5 |
| `Packages/CompassFIT/Sources/CompassFIT/Parsers/ActivityFITParser.swift` | **Modify** | 5 |
| `Packages/CompassFIT/Sources/CompassFIT/Parsers/FITDecoder.swift` | **Delete** | 4 |
| `Packages/CompassFIT/Sources/CompassFIT/Overlay/harry_overlay.json` | **Delete** | 4 |
| `Packages/CompassFIT/Sources/CompassFIT/Overlay/FieldNameOverlay.swift` | **Delete** | 4 |
| `Packages/CompassFIT/Sources/CompassFIT/Overlay/OverlayModels.swift` | **Delete** | 4 |
| `Packages/CompassFIT/Sources/CompassFIT/Overlay/HarryOverlayNotes.swift` | **Delete** | 4 |
| `Packages/CompassFIT/Tests/CompassFITTests/FITDecoderTests.swift` | **Rewrite or delete** | 4 |
| `Packages/CompassFIT/Tests/CompassFITTests/OverlayTests.swift` | **Rewrite or delete** | 4 |

---

## Known Risks

- **roznet/FitFileParser decodes messages differently.** It returns named-field dictionaries; our parsers currently use field-number integer keys. Field name strings must match exactly between the generated code and parser call-sites. Run all sample files through both decoders and diff before deleting FITDecoder.
- **Profile.aug.xlsx must stay in sync with NativeFITMessage.java.** When Gadgetbridge updates their message definitions, the augmentation script must be re-run. Add a `Makefile` or `scripts/update_profile.sh` to document the regeneration steps.
- **Message 274 (`sleep_data_raw`) may be device-generation-specific.** The Instinct Solar 1G may use a different first-byte encoding than newer devices. Guard any field-0 interpretation behind a firmware-version check once that data is available.
- **The `harry_overlay.json` content in `csv2json.py` and `harry_overlay_generated.json` in `data/Harry/` is superseded** by this work. Those files should be removed after Task 4 to avoid future confusion.
