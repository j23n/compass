import Foundation
import SwiftData
import CompassData

/// Shared GPX/FIT course importer. Used by both the in-app file picker and
/// the share-sheet / "Open in Compass" entry point on `CompassApp`.
///
/// Two-step flow so a UI layer can prompt the user about duplicates:
///
///   1. `parse(url:)` decodes the file into a `ParsedGPXCourse` (no
///      SwiftData side effects). Returns a `PreparedImport` value that
///      also carries the source URL and the detected duplicate (if any).
///   2. `commit(_:resolution:context:)` inserts the new `Course` into the
///      model context, optionally deleting the duplicate first.
///
/// Both steps are pure with respect to the file system except that
/// `commit` deletes the source file from `Documents/Inbox/` after a
/// successful insert, so the inbox doesn't accumulate cruft from
/// share-sheet imports.
public struct CourseImporter: Sendable {

    public enum ImporterError: LocalizedError {
        case unsupportedFileType(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedFileType(let ext):
                return "Unsupported file type: .\(ext). Compass imports .gpx and .fit course files."
            }
        }
    }

    /// What to do when an existing course matches the file being imported.
    public enum DuplicateResolution: Sendable {
        /// Replace the existing course (delete + insert). Loses any user
        /// edits to POI names/types on the old course.
        case overwrite
        /// Keep both — insert the new one alongside the existing.
        case duplicate
    }

    /// Result of parsing — the SwiftData write hasn't happened yet.
    public struct PreparedImport: Sendable {
        public let parsed: ParsedGPXCourse
        public let sourceURL: URL
        /// PersistentIdentifier of an existing course that looks like the
        /// same route (matched by name + similar total distance). Nil if
        /// none. Passed back to `commit` for the overwrite case.
        public let duplicateID: PersistentIdentifier?
        /// Display info about the duplicate, surfaced in the prompt.
        public let duplicateSummary: DuplicateSummary?

        public var hasDuplicate: Bool { duplicateID != nil }
    }

    /// User-visible info about the duplicate, for the confirmation prompt.
    public struct DuplicateSummary: Sendable {
        public let name: String
        public let totalDistance: Double
        public let importDate: Date
    }

    public init() {}

    // MARK: - Parse

    /// Decode the file at `url` and look for a content-matching existing
    /// course. Pure with respect to SwiftData — does not insert anything.
    public static func parse(url: URL, context: ModelContext) throws -> PreparedImport {
        let ext = url.pathExtension.lowercased()
        let data = try Data(contentsOf: url)

        let parsed: ParsedGPXCourse
        switch ext {
        case "gpx":
            parsed = try GPXCourseParser.parse(data: data)
        case "fit":
            parsed = try FITCourseParser.parse(data: data)
        default:
            throw ImporterError.unsupportedFileType(ext)
        }

        // Use the GPX/FIT track name if present, otherwise fall back to the
        // source filename without extension.
        let courseName = courseNameFromParsed(parsed, fallbackFilename: url.deletingPathExtension().lastPathComponent)

        let duplicate = findDuplicate(name: courseName, distance: parsed.totalDistance, in: context)

        return PreparedImport(
            parsed: ParsedGPXCourse(
                name: courseName,
                waypoints: parsed.waypoints,
                pointsOfInterest: parsed.pointsOfInterest,
                totalDistance: parsed.totalDistance,
                totalAscent: parsed.totalAscent,
                totalDescent: parsed.totalDescent
            ),
            sourceURL: url,
            duplicateID: duplicate?.persistentModelID,
            duplicateSummary: duplicate.map {
                DuplicateSummary(name: $0.name, totalDistance: $0.totalDistance, importDate: $0.importDate)
            }
        )
    }

    // MARK: - Commit

    /// Persist the imported course. If `prepared.hasDuplicate` and
    /// `resolution == .overwrite`, the matching existing course is deleted
    /// first. Always cleans up the source file from `Documents/Inbox/`
    /// after a successful save.
    @discardableResult
    public static func commit(
        _ prepared: PreparedImport,
        resolution: DuplicateResolution = .duplicate,
        context: ModelContext
    ) throws -> Course {
        if resolution == .overwrite, let dupID = prepared.duplicateID {
            if let existing = context.model(for: dupID) as? Course {
                context.delete(existing)
            }
        }

        let course = makeCourse(from: prepared.parsed)
        context.insert(course)
        try context.save()

        // Inbox cleanup — share-sheet "Open in" copies the file into
        // <App>/Documents/Inbox/ and never removes it. Only delete when
        // the URL is actually inside Inbox; for file-picker imports the
        // URL is a security-scoped reference and we must NOT delete it.
        cleanupIfInbox(prepared.sourceURL)

        return course
    }

    // MARK: - Helpers

    private static func makeCourse(from parsed: ParsedGPXCourse) -> Course {
        let waypoints = parsed.waypoints.enumerated().map { index, gpxWaypoint in
            CourseWaypoint(
                order: index,
                latitude: gpxWaypoint.latitude,
                longitude: gpxWaypoint.longitude,
                altitude: gpxWaypoint.altitude,
                name: gpxWaypoint.name,
                distanceFromStart: gpxWaypoint.distanceFromStart,
                timestamp: gpxWaypoint.timestamp
            )
        }
        let pois = parsed.pointsOfInterest.map { poi in
            CoursePOI(
                latitude: poi.latitude,
                longitude: poi.longitude,
                name: poi.name,
                coursePointType: Int(poi.coursePointType),
                distanceFromStart: poi.distanceFromStart
            )
        }
        let course = Course(
            name: parsed.name,
            importDate: Date(),
            sport: .running,
            totalDistance: parsed.totalDistance,
            totalAscent: parsed.totalAscent,
            totalDescent: parsed.totalDescent,
            waypoints: waypoints
        )
        course.pointsOfInterest = pois
        return course
    }

    private static func courseNameFromParsed(_ parsed: ParsedGPXCourse, fallbackFilename: String) -> String {
        let trimmed = parsed.name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? fallbackFilename : trimmed
    }

    /// Find an existing course whose name matches (case-insensitive) and
    /// whose total distance is within 1% of `distance`. The distance check
    /// catches the common case where the same route is exported from
    /// different sources (Komoot vs Garmin Connect) with slightly different
    /// path simplification, while ruling out unrelated routes that happen
    /// to share a name.
    private static func findDuplicate(name: String, distance: Double, in context: ModelContext) -> Course? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()

        // Predicate-side filtering on a lowercased name keeps the candidate
        // set small; the distance window is checked in-memory because
        // SwiftData predicates don't support abs() / floating-point ranges
        // ergonomically.
        let fetch = FetchDescriptor<Course>(
            predicate: #Predicate { $0.name.localizedStandardContains(trimmed) }
        )
        let candidates = (try? context.fetch(fetch)) ?? []
        let tolerance = max(50.0, distance * 0.01)  // 1% or 50 m, whichever is larger
        return candidates.first { existing in
            existing.name.lowercased() == lowered
                && abs(existing.totalDistance - distance) <= tolerance
        }
    }

    private static func cleanupIfInbox(_ url: URL) {
        // Inbox is always inside the app's Documents/Inbox/.
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        let inbox = docs.appendingPathComponent("Inbox", isDirectory: true)
        let standardisedURL = url.standardizedFileURL.path
        let standardisedInbox = inbox.standardizedFileURL.path
        guard standardisedURL.hasPrefix(standardisedInbox) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
