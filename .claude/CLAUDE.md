# Compass — project guide for Claude

## Architecture
Read [`docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md) before starting any task. It covers:
- Package structure and dependency rules (`CompassBLE` / `CompassFIT` / `CompassData` / app target)
- Annotated directory tree (every file with its purpose)
- Data flow from BLE bytes through FIT parsing into SwiftData
- SwiftData model table, concurrency model, DI approach, view hierarchy

## Garmin protocol docs
When working on BLE or protocol code, read [`docs/garmin/README.md`](../docs/garmin/README.md) first — it is the navigation index and quick-reference for the full protocol stack. The `references/` subdirectory contains authoritative Java-source walkthroughs from Gadgetbridge; consult them when the watch's actual behaviour is ambiguous.

## Conventions

As part of the Localapp family, stick to the [conventions](https://github.com/j23n/localapps/blob/main/.claude/CONVENTIONS.md) (try first locally at <REPO_ROOT>/../localapps/.claude/CONVENTIONS.md)
