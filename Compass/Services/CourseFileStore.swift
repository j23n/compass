import Foundation

/// Debug staging area for course FIT files uploaded to the watch.
///
/// Mirrors the bytes that go over BLE so they can be inspected, exported,
/// and run through external FIT validators when the watch silently rejects
/// a course post-upload.
final class CourseFileStore: @unchecked Sendable {
    nonisolated(unsafe) static let shared = CourseFileStore()

    struct StoredFile: Identifiable {
        let id: UUID
        let url: URL
        let name: String
        let size: Int64
        let date: Date
    }

    let directory: URL

    private init() {
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = docDir.appendingPathComponent("CourseFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Copy a course FIT file into the staging area, prefixed with a timestamp
    /// so successive uploads of the same course don't overwrite each other.
    @discardableResult
    func save(from url: URL) throws -> URL {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let dateStr = dateFormatter.string(from: Date())

        let original = url.deletingPathExtension().lastPathComponent
        let newName = "\(dateStr)_\(original).fit"
        let destinationURL = directory.appendingPathComponent(newName)

        try FileManager.default.copyItem(at: url, to: destinationURL)
        return destinationURL
    }

    func allFiles() -> [StoredFile] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else {
            return []
        }

        return contents.compactMap { url -> StoredFile? in
            guard url.pathExtension.lowercased() == "fit" else { return nil }

            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let date = (attrs?[.modificationDate] as? Date) ?? Date()

            return StoredFile(
                id: UUID(),
                url: url,
                name: url.lastPathComponent,
                size: size,
                date: date
            )
        }
        .sorted { $0.date > $1.date }
    }

    func delete(_ file: StoredFile) throws {
        try FileManager.default.removeItem(at: file.url)
    }
}
