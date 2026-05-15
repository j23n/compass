# Background sync writes to a separate `ModelContext`; UI doesn't refresh until manual sync

After a watch-initiated sync (the "background" path that fires when the
watch pushes files on its own schedule, while the user is on another
screen or before opening Compass), none of the freshly parsed
health/activity rows show up in the UI. Hitting the manual "Sync" button
afterwards immediately surfaces them — even though the parser code,
de-dup logic, and SwiftData models are identical between the two paths.

**Status: fixed.** `processWatchInitiatedURLs`, `importFITFiles`, and
`reparseLocalFITFiles` now write through `modelContainer.mainContext`
instead of constructing a detached `ModelContext(modelContainer)`. All
three were on the main actor already (SyncCoordinator is `@MainActor`),
so the change is straight-line.

## Symptom

1. Watch wakes the iPhone via BLE, Compass receives files in the
   background.
2. Logs show `Sync: saved file[N] …` and per-parser debug lines
   ("Inserted N HRV samples", "Inserted activity: …", etc.).
3. Open Compass. Today / Activities / Health detail views show **stale
   data** — last-update timestamp from before the watch-initiated sync.
4. Tap "Sync" manually. The same files (already cached locally) are
   re-parsed and the UI populates with everything from the prior
   background batch.

## Root cause sketch

`SyncCoordinator` has two parse-and-persist entry points and they
diverge on which `ModelContext` they write to:

- **Manual sync** (`SyncCoordinator.swift:449` — `func sync(context:)`)
  is called from `TodayView.swift:292` as
  `syncCoordinator.sync(context: modelContext)`. The argument is the
  view's `@Environment(\.modelContext)` — the same context every
  `@Query` in the UI is observing. Inserts and `context.save()` happen
  on this UI-attached context, so SwiftUI re-runs the queries
  immediately.

- **Watch-initiated sync**
  (`SyncCoordinator.swift:898` — `processWatchInitiatedURLs`) creates
  its own context inline:

  ```swift
  private func processWatchInitiatedURLs(_ entries: …) async {
      beginBackgroundTask()
      defer { endBackgroundTask() }
      let context = ModelContext(modelContainer)   // ← detached from UI
      await processFITFiles(entries, context: context)
  }
  ```

  Same `ModelContainer`, but a separate context. `parseAndFinalize`
  saves it with `try? context.save()` (line 560), which writes to the
  store — but iOS/SwiftData does not reliably republish those changes
  to the main-actor context backing `@Query` until that context is
  refreshed (re-fetched, app foregrounded with autosave on, or the
  query view re-instantiated). The manual sync then succeeds because it
  writes through the UI context directly.

`importFITFiles` (line 568) and `reparseLocalFITFiles` (line 595) follow
the same detached-context pattern as `processWatchInitiatedURLs`, so the
import / reparse buttons in Settings will hit the same issue if invoked
while the app is foreground but the UI hasn't rebuilt its queries.

## Why this is a real bug, not just a SwiftUI quirk

SwiftData *should* propagate cross-context changes via persistent-store
remote-change notifications, but in practice, iOS 17/18 `@Query` doesn't
always pick up writes from background contexts unless:

- The container is configured for cloud-kit-style remote changes (we
  don't enable this), or
- The receiving context is explicitly told to refresh
  (`context.refreshAllObjects()` or a re-fetch), or
- A new `@Query` instance is created (e.g. by the view re-appearing).

Compass relies on the third — coming back to the screen *after* a
manual sync re-runs the queries — and that's why manual sync "fixes"
it. Background sync hits no such trigger.

## Suggested fixes (in increasing scope)

1. **Hop to the main actor for the UI-context save.** After
   `parseAndFinalize` finishes on the detached context, dispatch a
   `Task { @MainActor in mainContext.refreshAllObjects() }` on the
   container's main context. Cheapest, no architectural change.
2. **Have `processWatchInitiatedURLs` use the main-actor context.**
   Pass the SwiftData container's `mainContext` (or one obtained from
   `@MainActor`) into `processFITFiles` instead of constructing a
   detached one. This trades off background-isolation for guaranteed
   UI consistency.
3. **Single shared `Observable` cache layer between sync and UI.**
   Stop relying on `@Query` for live updates from background work; have
   `SyncCoordinator` publish an `@Observable` snapshot the UI reads.
   Larger refactor, but resolves several adjacent issues (e.g. progress
   updates already use this pattern).

(1) is the right first try.

## References

- `Compass/App/SyncCoordinator.swift:449` (`sync(context:)`)
- `Compass/App/SyncCoordinator.swift:525` (`processFITFiles`)
- `Compass/App/SyncCoordinator.swift:550` (`parseAndFinalize`)
- `Compass/App/SyncCoordinator.swift:631` (`parseAndPersistFITFile`)
- `Compass/App/SyncCoordinator.swift:898` (`processWatchInitiatedURLs`)
- `Compass/App/CompassApp.swift:8-43` (container creation)
- `Compass/Views/Today/TodayView.swift:292` (manual sync trigger)
