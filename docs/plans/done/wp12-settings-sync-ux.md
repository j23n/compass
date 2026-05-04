# WP-12 · Settings & Sync UX — Implementation Plan

Five small fixes that together make the settings + sync surface feel coherent:
- Logs view auto-scrolls on open
- Sleep files reliably get the archive flag (parsing-failure interaction)
- Connection pill becomes a proper pill with device name + status + active operation
- Disconnect / Connect buttons move inline into the device row
- "Last sync …" line is replaced by sync progress while a sync runs

The connection-pill richer rendering builds on `ConnectionSyncStatusView` from WP-7 — that view already exists, this WP iterates on it. Sleep marked-as-read is the user-visible companion to the sleep-parser fix in WP-9 Task 6; this plan covers only the surface.

## Current State

| Area | File:line | Current behaviour |
|---|---|---|
| Logs auto-scroll | `LogsView.swift:44-47, 104-113` | `onAppear` sets `isFollowing = true`; scroll only fires on `.onChange(of: filteredEntries.count)`. **No scroll on initial appearance** — opening the view shows the top of the buffer. |
| Sleep "marked as read" | `SyncCoordinator.swift:602-604` | `archiveFITFile(fileIndex:)` only when `parsedOK == true`. WP-9 Task 6 makes more sleep files parse successfully; the surface-side gap is that the user has no way to manually re-archive a file that the parser legitimately couldn't handle. |
| Connection pill | `Compass/Components/ConnectionSyncStatusView.swift` | Toolbar-bar caption-style row: dot + short text, or progress + label while syncing. **Not visually a pill** — no background capsule, no fixed height. Shows abbreviated state only. |
| Settings device row | `SettingsView.swift:103-148` | Device name + status text + a coloured dot. **Connect / Disconnect buttons live in their own list rows below** the device row (lines 136-147). The rows are visually disconnected. |
| Last-sync line | `SettingsView.swift:235-244` | "Last sync … <date>" rendered unconditionally when `lastSyncDate != nil`. Sync progress (line 210-233) is rendered as a separate row above it. **Both visible during sync.** |

---

## Implementation Order

1. **Task 1 — Logs auto-scroll on first appear**
2. **Task 2 — Sleep "force re-archive" affordance** (manual safety valve; pairs with WP-9 Task 6)
3. **Task 3 — Replace last-sync line with sync progress** (cleanest of the three settings changes; foundation for Task 4)
4. **Task 4 — Inline Connect / Disconnect in the device row**
5. **Task 5 — `ConnectionSyncStatusView` → real pill**

Independent except 3→4 (both touch the device section layout).

---

## Task 1 — Logs Auto-Scroll on First Appear

**Risk: LOW** — one extra trigger.

### `Compass/Views/Settings/LogsView.swift`

The current `.onChange(of: filteredEntries.count)` only scrolls when the buffer grows. Add a `.task` to scroll once on appearance:

```swift
ScrollViewReader { proxy in
    List(filteredEntries, id: \.id) { entry in
        logListRow(for: entry).id(entry.id)
    }
    .listStyle(.plain)
    .task(id: filteredEntries.count) {
        // First fire: initial appear; subsequent fires: when count changes (covers
        // both first-render and live updates).
        if isFollowing, let last = filteredEntries.last {
            // One run-loop hop ensures the List has measured before we scroll.
            await Task.yield()
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }
    .onChange(of: isFollowing) { _, following in
        if following, let last = filteredEntries.last {
            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }
}
```

Drop the now-redundant `.onChange(of: filteredEntries.count)` (the `task(id:)` covers both cases).

The `Task.yield()` is the difference between the scroll firing before the list has laid out (no-op) and after (visible). Without it, opening from the Settings sheet sometimes still shows the top.

**Acceptance criteria**
- Opening the Logs view from a non-empty log buffer scrolls to the bottom before the first frame is interactive.
- The "follow" toggle still works the same way.
- The auto-scroll respects the search filter — applying a filter then opening shows the last *matching* entry.

---

## Task 2 — Sleep "Force Re-Archive" Affordance

**Risk: LOW** — adds a developer-section action; no impact on normal flow.

### Background

WP-9 Task 6 fixes the most common cause of unarchived sleep files (assessment-only files were silently dropped). What remains is the corner case: a sleep file the parser genuinely cannot handle (corrupted blob, a profile we haven't decoded yet). Today such a file is re-listed by the watch on every sync forever.

### Add to `FITFilesView.swift` row swipe actions

A new "Mark Synced" action that calls `syncCoordinator.archiveFITFile(named:)`:

```swift
.swipeActions(edge: .trailing, allowsFullSwipe: false) {
    if !isSelectionMode {
        ShareLink(item: file.url) { Label("Share", systemImage: "square.and.arrow.up") }
            .tint(.blue)
        Button {
            Task { await syncCoordinator.archiveFITFile(named: file.name) }
        } label: {
            Label("Mark Synced", systemImage: "checkmark.circle")
        }
        .tint(.green)
        Button(role: .destructive) { deleteFile(file) } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}
```

### `SyncCoordinator.archiveFITFile(named:)`

The store's filename pattern is `{type}_{datetime}_{fileIndex}.fit`. Parse `fileIndex` from the trailing component and forward to `deviceManager.archiveFITFile(fileIndex:)`. Log if the device is offline (no-op in that case; the action is best-effort).

```swift
extension SyncCoordinator {
    func archiveFITFile(named filename: String) async {
        guard let idStr = filename
                .replacingOccurrences(of: ".fit", with: "")
                .split(separator: "_").last,
              let fileIndex = UInt16(idStr)
        else {
            AppLogger.sync.warning("Cannot derive fileIndex from \(filename)")
            return
        }
        await deviceManager.archiveFITFile(fileIndex: fileIndex)
        AppLogger.sync.info("Manually archived fileIndex=\(fileIndex)")
    }
}
```

**Acceptance criteria**
- Swiping a FIT file row shows three actions: Share / Mark Synced / Delete.
- Tapping "Mark Synced" while connected logs the manual archive and the watch stops re-listing that file on the next sync.
- Tapping while disconnected logs a warning and does not crash.

---

## Task 3 — Sync Progress Replaces Last-Sync Line

**Risk: LOW** — conditional swap.

### `SettingsView.swift:235-244` (the sync section)

Today both lines are visible during sync. Make the "Last sync" row conditional on **not** syncing, and let the existing sync-state row carry the live information:

```swift
// Sync state description
switch syncCoordinator.state {
case .syncing(let description):
    HStack {
        ProgressView().controlSize(.small).tint(.blue)
        Text(description)
            .font(.subheadline)
            .foregroundStyle(.primary)
        Spacer()
        if syncCoordinator.progress > 0 {
            Text("\(Int(syncCoordinator.progress * 100))%")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
case .completed(let fileCount):
    Text("Synced \(fileCount) file\(fileCount == 1 ? "" : "s")")
        .font(.subheadline)
        .foregroundStyle(.green)
case .failed(let message):
    Text(message)
        .font(.subheadline)
        .foregroundStyle(.red)
case .idle:
    if let lastSync = syncCoordinator.lastSyncDate {
        HStack {
            Text("Last sync").foregroundStyle(.secondary)
            Spacer()
            Text(lastSync, format: .dateTime.month(.abbreviated).day().hour().minute())
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }
}
```

Two visible behaviours change:
- During `.syncing`, the row goes from caption-grey ("Listing activity files…") to subheadline-primary with a leading spinner — visually the same row real-estate as "Last sync …" so the swap is in-place.
- The standalone "Last sync …" row no longer renders during sync; it returns when state goes back to `.idle`.

`.completed` is transient — `SyncCoordinator` resets to `.idle` after a moment, so the green confirmation flashes briefly then "Last sync …" returns with the updated timestamp.

**Acceptance criteria**
- During a sync, the settings sync section shows exactly one row: spinner + description + (optional) percent.
- After completion, "Synced N files" appears briefly in green, then is replaced by "Last sync … <fresh date>".
- On failure, the red message persists until the next sync attempt; "Last sync" stays hidden.

---

## Task 4 — Inline Connect / Disconnect in Device Row

**Risk: LOW** — moves two buttons; no state changes.

### `SettingsView.swift:103-147` (deviceSection)

Today the row is `HStack(icon, name+status, dot)`. The Disconnect / Reconnect buttons sit in their own rows below.

Rework the row to:

```
[icon]  Device Name                         [Disconnect]
        Connected · Listing activity…       [chevron]
                                            <connection dot>
```

Concretely:

```swift
HStack(spacing: 12) {
    Image(systemName: "applewatch")
        .font(.title2)
        .foregroundStyle(.blue)

    VStack(alignment: .leading, spacing: 2) {
        Text(device.name).font(.body).fontWeight(.medium)
        Text(currentStatusLine)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    Spacer()

    inlineConnectionButton
}
```

Where `inlineConnectionButton` is:

```swift
@ViewBuilder
private var inlineConnectionButton: some View {
    switch syncCoordinator.connectionState {
    case .connected:
        Button("Disconnect") {
            Task { await syncCoordinator.manualDisconnect() }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(.red)

    case .disconnected, .failed:
        Button("Connect") {
            syncCoordinator.manualReconnect()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)

    case .connecting, .reconnecting:
        ProgressView().controlSize(.small)
    }
}
```

`currentStatusLine` returns `connectionStatusLabel` from today's helpers, but augmented when syncing:

```swift
private var currentStatusLine: String {
    if case .syncing(let desc) = syncCoordinator.state {
        return "\(connectionStatusLabel) · \(desc)"
    }
    return connectionStatusLabel
}
```

The two standalone Disconnect / Reconnect rows go away. The "Last synced … N min ago" sub-row from `device.lastSyncedAt` (lines 149-160) also goes — it duplicates the sync-section "Last sync" line; one source of truth is enough.

**Acceptance criteria**
- The device row contains everything related to the watch: icon, name, current state, action button.
- Tapping Disconnect / Connect from the row triggers the same actions as before.
- During a sync, the status line reads "Connected · Listing activity files…" inside the device row.
- The connection dot is gone (button colour communicates the same thing more clearly).

---

## Task 5 — `ConnectionSyncStatusView` → Real Pill

**Risk: LOW** — visual upgrade plus more content; existing display-mode logic is preserved.

### Goal

The toolbar indicator is currently caption-styled text-on-bar. Promote it to a capsule with:
- Coloured dot (existing connection-state semantics)
- Device name (when known)
- Trailing operation text — "Listing activity files…", "12.3 MB / 45 MB", "Sync failed", or empty when idle-connected

Visually:

```
( ● Forerunner 245   ·  Listing activity… )    when syncing
( ● Forerunner 245                         )    when idle-connected
( ● Reconnecting…                          )    when reconnecting
( ● Not connected                          )    when no device
```

### `Compass/Components/ConnectionSyncStatusView.swift` — restructured

```swift
var body: some View {
    HStack(spacing: 6) {
        statusDot
        Text(primaryLabel)
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
        if let secondary = secondaryLabel {
            Text("·").foregroundStyle(.tertiary)
            HStack(spacing: 4) {
                if isSyncing {
                    ProgressView().controlSize(.mini).tint(.secondary)
                }
                Text(secondary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(.ultraThinMaterial, in: Capsule())
    .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityDescription)
}

private var statusDot: some View {
    Circle().fill(connectionDotColor).frame(width: 8, height: 8)
}

private var isSyncing: Bool { if case .syncing = sync.state { return true } else { return false } }

private var primaryLabel: String {
    if case .failed = sync.state { return "Sync failed" }
    return connectionLabel        // existing helper — device name when connected
}

private var secondaryLabel: String? {
    switch sync.state {
    case .syncing(let desc):
        if let bytes = sync.transferBytes {           // see note below
            return "\(byteString(bytes.received)) / \(byteString(bytes.total ?? 0))"
        }
        if sync.progress > 0 { return "\(Int(sync.progress * 100))%" }
        return abbreviated(desc)
    default: return nil
    }
}
```

### `SyncCoordinator` — expose download bytes

The current `SyncProgress.downloading(file:bytesReceived:totalBytes:)` already carries bytes; `SyncCoordinator.swift:378` has the values but only stores a 0…1 `progress` float. Add an optional `transferBytes: (received: Int, total: Int?)?` property updated in the same `case .downloading` branch:

```swift
case .downloading(_, let received, let total):
    progress = total.map { Double(received) / Double($0) } ?? 0
    transferBytes = (received, total)
```

Reset to nil in `.completed` / `.idle` transitions.

### Pill width on small phones

The pill grows to fit content; capping at ~220 pt on iPhone SE prevents collision with the centred title:

```swift
.frame(maxWidth: 220, alignment: .leading)
```

`.lineLimit(1)` + `.truncationMode(.tail)` on the secondary label do the rest. The primary (device name) is short by nature.

### Tappable

Wrap the pill in a `Button` that opens Settings:

```swift
Button { showSettings = true } label: { /* pill body */ }
    .buttonStyle(.plain)
```

`showSettings` lives on the parent (each tab root); easiest route is a `@Environment(\.openSettings)` style action, but practically: emit a notification or use a shared `@Observable` UIState. The existing settings entry on Today is a toolbar gear; adding a second entry (the pill itself) is reasonable on every tab. If wiring is awkward, defer the tap target — the visual upgrade is the win.

**Acceptance criteria**
- The toolbar item is a visible pill with a thin material background and rounded corners.
- Idle + connected: shows ` ● <Device Name> ` only.
- Syncing: shows ` ● <Device Name> · <progress> ` with a tiny spinner before the progress text.
- Failed: shows ` ● Sync failed ` (red dot).
- Tapping (if wired) opens Settings.

---

## Files to Modify

| File | Tasks |
|---|---|
| `Compass/Views/Settings/LogsView.swift` | 1 |
| `Compass/Views/Settings/FITFilesView.swift` | 2 |
| `Compass/App/SyncCoordinator.swift` | 2 (new `archiveFITFile(named:)`), 5 (`transferBytes` property) |
| `Compass/Views/Settings/SettingsView.swift` | 3 (sync row swap), 4 (inline Connect/Disconnect, drop standalone rows) |
| `Compass/Components/ConnectionSyncStatusView.swift` | 5 (capsule layout, secondary label, optional tap) |

---

## Known Limitations

- **Manual archive (Task 2) is fire-and-forget.** No UI feedback beyond a log line. If the watch is offline the action no-ops silently. Acceptable for a developer-oriented action; revisit if it surfaces to non-developer users.
- **Pill tap-to-open-settings (Task 5) is optional.** Wiring it through the existing tab roots requires either a shared `@Observable` UIState or per-tab plumbing. If the easier path doesn't exist, skip the tap and keep the gear icon as the entry point.
- **`transferBytes` accuracy.** When `total` is unknown (Garmin sometimes returns `maxFileSize=0`), the secondary label falls back to the description / percent. The "12.3 MB / 45 MB" rendering only happens when both are known.
- **Last-sync date source of truth (Task 4).** Removing the device-row "Last synced … N min ago" leaves the sync section as the only place the date is visible. The `device.lastSyncedAt` field stays in the model — it's authoritative — we just don't render it twice.
- **Pill width on iPad / wide layouts.** Capped at 220 pt regardless of screen size; on iPad this looks small but doesn't collide with anything. Tunable later.
