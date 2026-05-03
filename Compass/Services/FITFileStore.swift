import Foundation

final class FITFileStore: @unchecked Sendable {
    nonisolated(unsafe) static let shared = FITFileStore()

    struct StoredFile: Identifiable {
        let id: UUID
        let url: URL
        let name: String
        let size: Int64
        let date: Date
        let type: FITFileType
    }

    enum FITFileType: String, CaseIterable {
        case activity, monitor, sleep, metrics, unknown

        var displayName: String {
            switch self {
            case .activity: "Activity"
            case .monitor: "Monitor"
            case .sleep: "Sleep"
            case .metrics: "Metrics"
            case .unknown: "Unknown"
            }
        }

        var systemImage: String {
            switch self {
            case .activity: "figure.run"
            case .monitor: "heart.text.square"
            case .sleep: "moon.zzz"
            case .metrics: "chart.bar"
            case .unknown: "doc"
            }
        }
    }

    let directory: URL

    private init() {
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = docDir.appendingPathComponent("FITFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func save(from url: URL, fileIndex: UInt16? = nil) throws -> URL {
        let filename = url.lastPathComponent.lowercased()
        let fileType = detectType(from: filename)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let dateStr = dateFormatter.string(from: Date())
        let suffix = fileIndex.map { String($0) } ?? String(UUID().uuidString.prefix(8))

        let newName = "\(fileType.rawValue)_\(dateStr)_\(suffix).fit"
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

        let files = contents.compactMap { url -> StoredFile? in
            guard url.pathExtension.lowercased() == "fit" else { return nil }

            let filename = url.lastPathComponent.lowercased()
            let fileType = detectType(from: filename)

            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let date = (attrs?[.modificationDate] as? Date) ?? Date()

            return StoredFile(
                id: UUID(),
                url: url,
                name: url.lastPathComponent,
                size: size,
                date: date,
                type: fileType
            )
        }

        return files.sorted { $0.date > $1.date }
    }

    func delete(_ file: StoredFile) throws {
        try FileManager.default.removeItem(at: file.url)
    }

    func deleteAll() throws {
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func detectType(from filename: String) -> FITFileType {
        if filename.contains("activity") || filename.contains("act") {
            return .activity
        } else if filename.contains("monitor") || filename.contains("mon") {
            return .monitor
        } else if filename.contains("sleep") || filename.contains("slp") {
            return .sleep
        } else if filename.contains("metric") || filename.contains("met") {
            return .metrics
        }
        return .unknown
    }
}
