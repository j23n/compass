import Foundation

@Observable
final class LogStore: @unchecked Sendable {
    nonisolated(unsafe) static let shared = LogStore()

    struct Entry: Identifiable {
        let id: UUID = UUID()
        let timestamp: Date
        let level: Level
        let category: String
        let message: String

        enum Level: String, CaseIterable {
            case debug, info, warning, error

            var displayName: String {
                self.rawValue.uppercased()
            }
        }
    }

    private(set) var entries: [Entry] = []
    private let maxEntries = 2000

    private init() {}

    func append(level: Entry.Level, category: String, message: String) {
        let entry = Entry(timestamp: Date(), level: level, category: category, message: message)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func clear() {
        entries = []
    }

    var asText: String {
        entries.map { entry in
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "HH:mm:ss.SSS"
            let timeStr = timeFormatter.string(from: entry.timestamp)
            return "[\(timeStr)] [\(entry.level.displayName)] [\(entry.category)] \(entry.message)"
        }.joined(separator: "\n")
    }
}
