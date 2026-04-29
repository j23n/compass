import SwiftUI
import UIKit

struct LogsView: View {
    @State private var filterLevel: LogStore.Entry.Level? = nil
    @State private var showShareSheet = false
    @State private var showCopyAlert = false
    @State private var logStore = LogStore.shared
    @State private var shareItems: [URL] = []

    private var filteredEntries: [LogStore.Entry] {
        if let level = filterLevel {
            return logStore.entries.filter { $0.level == level }
        }
        return logStore.entries
    }

    private var levelColors: [LogStore.Entry.Level: Color] {
        [
            .debug: .blue,
            .info: .green,
            .warning: .orange,
            .error: .red,
        ]
    }

    var body: some View {
        NavigationStack {
            contentBody
                .navigationTitle("Logs")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        filterMenu
                    }

                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            UIPasteboard.general.string = getLogsText()
                            showCopyAlert = true
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }

                        Button {
                            if let url = createLogsFile() {
                                shareItems = [url]
                                showShareSheet = true
                            }
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
                .sheet(isPresented: $showShareSheet) {
                    ActivityView(items: shareItems)
                }
                .alert("Copied", isPresented: $showCopyAlert) {
                    Button("OK") {}
                } message: {
                    Text("Logs copied to clipboard")
                }
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        if filteredEntries.isEmpty {
            ContentUnavailableView {
                Label("No Logs", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text("Logs will appear here as the app runs.")
            }
        } else {
            logsList
        }
    }

    @ViewBuilder
    private var logsList: some View {
        List(filteredEntries, id: \.id) { entry in
            logListRow(for: entry)
        }
        .listStyle(.plain)
    }

    private func logListRow(for entry: LogStore.Entry) -> some View {
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss.SSS"

        return HStack(spacing: 12) {
            Circle()
                .fill(levelColors[entry.level] ?? .gray)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(timeFormatter.string(from: entry.timestamp))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(entry.category)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(4)

                    Spacer()

                    Text(entry.level.displayName)
                        .font(.caption2)
                        .foregroundStyle(levelColors[entry.level] ?? .gray)
                }

                Text(entry.message)
                    .font(.caption)
                    .lineLimit(3)
                    .foregroundStyle(.primary)
            }
        }
        .padding(.vertical, 4)
    }

    private var filterMenu: some View {
        Menu {
            Button {
                filterLevel = nil
            } label: {
                HStack {
                    if filterLevel == nil {
                        Image(systemName: "checkmark")
                    }
                    Text("All")
                }
            }

            Divider()

            ForEach(LogStore.Entry.Level.allCases, id: \.self) { level in
                Button {
                    filterLevel = level
                } label: {
                    HStack {
                        if filterLevel == level {
                            Image(systemName: "checkmark")
                        }
                        Text(level.displayName)
                    }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
    }

    private func getLogsText() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        return logStore.entries.map { entry in
            "[\(dateFormatter.string(from: entry.timestamp))] [\(entry.level.displayName)] [\(entry.category)] \(entry.message)"
        }.joined(separator: "\n")
    }

    private func createLogsFile() -> URL? {
        let text = getLogsText()
        let fileName = "compass-logs-\(Date().formatted(date: .abbreviated, time: .standard)).txt"
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(fileName)

        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            return nil
        }
    }
}

#Preview {
    LogsView()
}
