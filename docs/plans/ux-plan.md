# UX Plan

## Tab structure

**Today** | **Activities** | **Health**

Settings stays as a gear-icon sheet launched from Today (no change).

---

## Today

### What changes
- Remove the 4 big progress rings (`RingsView` / `RingView`). Replace with a compact **2-column vitals grid** (6 cards, ~88pt each):
  - Sleep Score (purple · sleep stage mini-bar as decoration)
  - Resting HR (red · sparkline)
  - Body Battery (blue · current value + tiny trend arrow)
  - Stress (orange · current value + tiny trend arrow)
  - Steps (green · count)
  - Active Minutes (teal · count)
- Move body battery and stress **charts** out of Today — they live in Health. Today shows current values only.
- Change activity filter from `>= startOfDay` to `>= now - 24h`. Section header becomes "Recent Activities".
- Connection pill stays top-right, unchanged.

### Files
| Action | File |
|---|---|
| New | `Views/Today/VitalsGridView.swift` |
| Modify | `Views/Today/TodayView.swift` |
| Retire | `Components/RingsView.swift`, `Components/RingView.swift` |

---

## Activities (new tab, middle)

### Layout
```
NavigationStack
  Large title "Activities"
  Horizontal sport filter chips (scrollable):
    All · Running · Cycling · Swimming · Hiking · Walking · Strength · Cardio
  List (reverse-chronological):
    [Colored sport icon circle] [Name + date + distance + duration] [Map thumbnail 60×60]  ›
  Empty state: "No [Sport] activities yet"
```

### Map thumbnail
`MKMapSnapshotter` static image (60×60 pt, rounded rect). Falls back to a gray placeholder with a map icon if there are no GPS track points or the snapshot is still loading.

### Files
| Action | File |
|---|---|
| New | `Views/Activity/ActivitiesListView.swift` |
| New | `Views/Activity/ActivityRowView.swift` |
| New | `Views/Activity/MapSnapshotView.swift` |

---

## Activity detail

### What changes
- Replace the gray placeholder box with a real **`MKMapView`** (UIViewRepresentable), full-width, 260 pt tall.
  - Route drawn as a coloured `MKPolyline` overlay.
  - Green start pin + red end pin annotations.
  - Falls back to a styled "No GPS data" placeholder if track points are empty.
- Stats grid: expand from 2×2 to 2×3 — add Max HR and Calories.
- Elevation chart: unchanged.
- HR chart: add area fill gradient for polish.

### Files
| Action | File |
|---|---|
| New | `Views/Activity/MapRouteView.swift` |
| Modify | `Views/Activity/ActivityDetailView.swift` |

---

## Health

### Sections

| Section | Icon | Metrics | Chart type |
|---|---|---|---|
| Heart | `heart.fill` (red) | Resting Heart Rate, HRV | Line |
| Sleep | `bed.double.fill` (purple) | Sleep Duration | Bar |
| Recovery | `bolt.heart.fill` (blue) | Body Battery, Stress | Area + line |
| Activity | `figure.run` (green) | Steps, Active Minutes | Bar |

Each section header shows: icon · name · current/avg value · trend arrow (↑↓).

### Chart interaction — drag-to-read
- Drag finger across any chart → vertical rule follows touch
- Callout tooltip shows exact date + value at that position
- Implemented via Swift Charts `chartOverlay` + `DragGesture`
- Extracted into a reusable `ChartDragOverlay` component shared by Health and HealthDetail views

### Visual polish
- Stroke weight 2.5 pt (up from default ~1 pt)
- Richer gradient fills: opacity 0.3 → 0.0 top-to-bottom
- Section cards use `.background` fill + subtle shadow (existing card style, unchanged)

### Files
| Action | File |
|---|---|
| New | `Components/ChartDragOverlay.swift` |
| Modify | `Views/Health/HealthView.swift` |
| Modify | `Views/Health/HealthDetailView.swift` |

---

## Navigation change

| Action | File |
|---|---|
| Modify | `Views/ContentView.swift` — add Activities tab between Today and Health |

---

## Dependencies

None. MapKit is built into iOS and already available.
