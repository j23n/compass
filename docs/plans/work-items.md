# Work Items

Clustered from `todo.md` into implementation-ready work packages.

---

## WP-1 · BLE Connection Lifecycle

Everything related to how the app establishes, maintains, and tears down the BLE connection.

- **Reconnect / bond persistence** — skip full handshake on reconnect; use `mFirstConnect` flag to gate `SETUP_WIZARD_*` events; send `SYNC_READY` immediately on subsequent connects.
- **BLE heartbeat** — poll or observe GATT connection state so the UI always reflects the real connection status.
- **Seamless reconnect** — handle app moving between background and foreground without dropping the link.
- **Persistent background BLE connection** — keep the connection alive in the background ("where's my phone?" use-case).
- **Settings: manual disconnect / reconnect** — add explicit controls so the user can force a cycle.
- **Settings: swipe-to-delete paired watch** — remove the watch from the app *and* from iOS Bluetooth devices.
- **Sync cancel propagation** — thread the cancel signal all the way through the sync stack so the Cancel button in the UI actually stops the transfer.

---

## WP-2 · Sync Correctness & File Handling

Data integrity and reliability of the sync flow itself.

- **Fix "empty" first sync** — investigate and resolve the double-sync / empty-first-sync bug logged in `2026-05-01_double_sync_and_sleep.log`.
- **Fix hanging transfer when app is backgrounded** — related to persistent BLE; the transfer stalls if the app is not in the foreground.
- **Archive-after-processing, not after-receive** — files should only be marked as archived once they have been successfully parsed/stored, to prevent data loss on a failed first sync.
- **Parallel file-transfer handles (future)** — register ML services for `FILE_TRANSFER_2/4/6/A/C/E` (service codes `0x2018`–`0xE018`) to enable concurrent FIT downloads. Not required for correctness; deferred optimisation.

---

## WP-4 · Sleep Data Parsing

Two tightly coupled issues that must be solved together.

- **Understand sleep msg 274 blob format** — the 20-byte payloads are not simple `uint8` sleep-stage values; the last 2 bytes look like a ~60 s timestamp suffix; the preceding 18 bytes are unknown (actigraphy / HRV vectors?). Cross-reference Gadgetbridge's Instinct Solar (1st gen) sleep parser.
- **Implement sleep epoch decoder** — once the format is understood, replace the broken level parser with a correct implementation.
- **Fix broken sleep display in Health view** — the current parser produces no valid samples; the Health sleep card is non-functional.

---

## WP-3 · Data Parsing & FIT Field Mapping

Correctness of parsed metrics across all views.

- **Regenerate `harryoverlay.json`** — the current file appears to be fabricated. Rewrite the `xlsx2json.js` script (from `harryo/fit-reader`) in Python and run it against the authoritative Google Sheets FIT profile to produce a correct overlay. (Sheet URL in `todo.md`.)
- **Step count inconsistency** — steps are correct on Today view but wrong on Health view (including the detail card). Identify which parser / aggregation path diverges.
- **Active minutes calculation** — shows 2 minutes for a day with 60 min of biking; aggregation logic is wrong, or source is incorrect.
- **Rename "Resting Heart Rate" → "Heart Rate"** — display-name change across all views.


---

## WP-5 · Activity Detail View

A coherent redesign of the activity detail screen.

- **Metrics coverage pass** — audit every supported activity type (running, biking, boat, climbing, mtb, hiking, kayak, rowing, skiing, snowboarding, SUP, swimming, yoga, walk) and define which metrics (HR, altitude, speed, cadence, power, …) each must surface; fix biking missing altitude + speed.
- **Layout: swap map and stats** — show stats before the map; add section headings.
- **Stats: 3-column grid** — denser information layout (currently 2 columns).
- **Graphs: consistent popout** — use the same timestamp popout interaction and information as the health graphs.
- **Graphs: labelled axes** — x-axis from 0 to end timestamp; label both axes.
- **GPS trace ↔ graph linking** — tapping a graph data point should highlight the corresponding position on the map; currently only the start/end points work.
- **Altitude and speed graphs** — add the missing graph types for biking and other relevant activities.

---

## WP-6 · Health & Courses Views

Polish and correctness across the two secondary data views.

- **Health graphs: popout position bug** — the hover/tap popout appears on the wrong side (to the left of the bar instead of to the right / above).
- **Health details: summary table** — add mean and standard deviation to the summary list; align columns as a proper table.
- **Courses: "on watch" check** — the presence check is broken; investigate whether watch-side files are exposed over BLE at all.
- **Courses: 3-column stats layout** — align with the activity detail redesign (WP-5).
- **Courses: sport-type edit view** — move "sport type" into a dedicated edit screen that also lets the user rename the course.

---

## WP-7 · Navigation & Today View

Cross-cutting navigation consistency.

- **Today vitals chits → Health detail** — tapping a chit should navigate to the corresponding Health detail page (reuse the existing page, preserve back-navigation), rather than opening a bespoke inline view.
- **Navigation bar: connection + sync status** — surface the current BLE connection state and active sync progress in the navigation bar so it is visible from any screen.
