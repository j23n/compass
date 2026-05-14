import Foundation
import SwiftData
import CompassData
import CompassFIT
import Observation

/// App-level coordinator for course imports (file picker + share sheet).
///
/// Holds `pendingImport` so a SwiftUI sheet/alert can prompt the user about
/// duplicate courses regardless of which tab is active. Both entry points —
/// `CoursesListView`'s `.fileImporter` and `CompassApp`'s `.onOpenURL` —
/// funnel through `handle(url:context:)`, so the duplicate-detection rules
/// stay consistent.
@Observable
@MainActor
final class CourseImportCoordinator {

    /// Set when an import is parsed successfully but has a duplicate that
    /// needs user confirmation. The view binds a `.sheet(item:)` to this
    /// and the user picks overwrite / duplicate / cancel.
    var pendingImport: PendingImport?

    /// Last user-visible error, surfaced as an alert.
    var lastError: String?

    /// The course just inserted by a successful import. Drives auto-
    /// navigation: ContentView switches to the Courses tab and
    /// CoursesListView pushes the detail view. Consumers clear this back
    /// to nil after handling the navigation.
    var lastImportedCourse: Course?

    struct PendingImport: Identifiable {
        let id = UUID()
        let prepared: CourseImporter.PreparedImport
    }

    /// Begin an import. If the file parses and has no duplicate, commits
    /// directly. If it has a duplicate, stashes a `pendingImport` for the
    /// UI to resolve.
    func handle(url: URL, context: ModelContext) {
        // For file-picker URLs we have to scope the read; for inbox URLs
        // this is a no-op. Calling it unconditionally is safe.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let prepared = try CourseImporter.parse(url: url, context: context)
            if prepared.hasDuplicate {
                pendingImport = PendingImport(prepared: prepared)
            } else {
                let course = try CourseImporter.commit(prepared, resolution: .duplicate, context: context)
                lastImportedCourse = course
                AppLogger.sync.info("Imported course: \(prepared.parsed.name)")
            }
        } catch {
            lastError = error.localizedDescription
            AppLogger.sync.error("Course import error: \(error)")
        }
    }

    /// Resolve a pending duplicate import. `nil` resolution = user
    /// cancelled — discards the parsed data without inserting anything.
    func resolvePending(_ resolution: CourseImporter.DuplicateResolution?, context: ModelContext) {
        defer { pendingImport = nil }
        guard let pending = pendingImport, let resolution else { return }
        do {
            let course = try CourseImporter.commit(pending.prepared, resolution: resolution, context: context)
            lastImportedCourse = course
            AppLogger.sync.info("Imported course (\(String(describing: resolution))): \(pending.prepared.parsed.name)")
        } catch {
            lastError = error.localizedDescription
            AppLogger.sync.error("Course import commit error: \(error)")
        }
    }
}
