Tracked in detailed plans:

- [WP-8](wp8-fitdump-cli.md) — `fitdump` CLI for offline parser debugging
- [WP-9](wp9-parsing-fixes.md) — parsing regressions: HR / active minutes / sleep / steps;
  enhanced_* field fallbacks; per-timestamp dedup; diagnostic logging
- [WP-10](wp10-today-chits.md) — Today chits: per-interval intensity model, last-reading line,
  4-hour mini-chart, blood-oxygen chit
- [WP-11](wp11-graph-polish.md) — Charts: pinned y-domain, bar-selection containment,
  hourly Day buckets, pre-computed activity map↔chart index
- [WP-12](wp12-settings-sync-ux.md) — Settings/sync UX: logs auto-scroll, force-archive,
  inline Connect/Disconnect, sync-progress replaces last-sync line, real connection pill

Suggested execution order: WP-8 → WP-9 → WP-10 → WP-11 → WP-12.
WP-8 unblocks fast verification of WP-9.
WP-9 makes the data on Today / Health correct so WP-10 / WP-11 are visible wins.
WP-12 is independent of the others and can be picked up at any time.
